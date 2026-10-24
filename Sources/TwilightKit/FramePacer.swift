import AVFoundation
import CoreMedia
import QuartzCore

/// Smooths out network jitter (for example Wi-Fi AWDL stalls) by holding a few decoded-order frames
/// and releasing them to the decoder at the stream's frame rate, timed by the display.
///
/// Compressed frames can't be dropped without corrupting the frames that reference them, so when
/// the queue grows after a burst the pacer catches up by releasing two frames on a tick: both are
/// decoded and only the newer one is seen. If the queue runs dry it refills to its target depth
/// before resuming, which rebuilds the cushion for the next stall.
final class FramePacer: NSObject {
    private let release: (CMSampleBuffer) -> Void
    private let depth: Int
    private let frameInterval: CFTimeInterval
    private let fps: Float

    private let lock = NSLock()
    private var queue: [CMSampleBuffer] = []
    private var primed = false
    private var nextRelease: CFTimeInterval = 0
    #if os(macOS)
    private var timer: Timer?
    #else
    private var displayLink: CADisplayLink?
    #endif

    /// `release` receives each frame when it's due (normally the video renderer's `enqueue`).
    init(depth: Int, fps: Int, release: @escaping (CMSampleBuffer) -> Void) {
        self.release = release
        self.depth = max(1, depth)
        self.fps = Float(max(fps, 1))
        frameInterval = 1.0 / Double(max(fps, 1))
    }

    /// Frames currently waiting to be released.
    var bufferedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    func start() {
        DispatchQueue.main.async { [self] in
            #if os(macOS)
            // macOS is only used for tests; a timer at twice the frame rate stands in for vsync
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: frameInterval / 2, repeats: true) { [weak self] _ in
                self?.step(now: CACurrentMediaTime())
            }
            #else
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: max(fps, 120), preferred: fps)
            link.add(to: .main, forMode: .common)
            displayLink = link
            #endif
        }
    }

    func stop() {
        DispatchQueue.main.async { [self] in
            #if os(macOS)
            timer?.invalidate()
            timer = nil
            #else
            displayLink?.invalidate()
            displayLink = nil
            #endif
        }
        flush()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        queue.append(sampleBuffer)
        lock.unlock()
    }

    /// Drops everything waiting (after a decoder failure, the next frame will be an IDR).
    func flush() {
        lock.lock()
        queue.removeAll()
        primed = false
        lock.unlock()
    }

    #if !os(macOS)
    @objc private func tick(_ link: CADisplayLink) {
        step(now: link.targetTimestamp)
    }
    #endif

    /// One vsync: releases zero, one or two frames depending on timing and queue depth.
    /// Returns how many were released (for tests).
    @discardableResult
    func step(now: CFTimeInterval) -> Int {
        var released: [CMSampleBuffer] = []

        lock.lock()
        if !primed {
            if queue.count >= depth {
                primed = true
                nextRelease = now
            }
        }
        // Small tolerance so a release due a hair after this vsync isn't pushed a whole tick later
        if primed && now + 0.002 >= nextRelease {
            if queue.isEmpty {
                // Underrun: refill to the target depth before resuming
                primed = false
            } else {
                // Catch up gently when a burst has built the queue well past its target
                let count = queue.count > depth + 1 ? 2 : 1
                released = Array(queue.prefix(count))
                queue.removeFirst(count)
                nextRelease += frameInterval
                if nextRelease < now - frameInterval {
                    nextRelease = now + frameInterval
                }
            }
        }
        lock.unlock()

        for sampleBuffer in released {
            release(sampleBuffer)
        }
        return released.count
    }
}
