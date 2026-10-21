import SwiftUI
import TwilightKit

struct AddHostSheet: View {
    var onAdded: (HostRecord) -> Void
    @Environment(HostStore.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IP address or hostname", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(add)
                } footer: {
                    Text("For example 192.168.1.20, or gaming-pc.local. Add :port if the host uses a custom port.")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Add", action: add).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .frame(width: 520, height: 360)
    }

    private func add() {
        guard !address.isEmpty else { return }
        working = true
        error = nil
        Task {
            do {
                let record = try await hosts.addHost(address: address)
                onAdded(record)
                dismiss()
            } catch {
                self.error = "Couldn't reach a host at that address. \(error.localizedDescription)"
            }
            working = false
        }
    }
}

struct PairSheet: View {
    let host: HostRecord
    @Environment(HostStore.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    @State private var pin = Pairing.generatePin()
    @State private var phase: Phase = .waiting

    enum Phase: Equatable {
        case waiting, paired, failed(String)
    }

    var body: some View {
        VStack(spacing: 24) {
            switch phase {
            case .waiting:
                Text("Enter this PIN on \(host.name)")
                    .font(.title2)
                Text(pin)
                    .font(.system(size: 88, weight: .semibold, design: .rounded).monospacedDigit())
                    .tracking(12)
                Text("In Sunshine, open the web UI and go to PIN. With GeForce Experience, a PIN prompt appears on the host.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                ProgressView()
            case .paired:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(.green)
                Text("Paired with \(host.name)").font(.title2)
            case .failed(let message):
                Image(systemName: "xmark.octagon.fill").font(.system(size: 72)).foregroundStyle(.red)
                Text(message).multilineTextAlignment(.center)
                Button("Try Again") {
                    pin = Pairing.generatePin()
                    phase = .waiting
                }
            }

            Button(phase == .paired ? "Done" : "Cancel") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(48)
        .frame(width: 560)
        .task(id: pin) {
            guard phase == .waiting else { return }
            let result = await hosts.pair(host, pin: pin, deviceName: "Apple Vision Pro")
            switch result {
            case .paired:
                phase = .paired
                await hosts.refresh(host)
                try? await Task.sleep(for: .seconds(1))
                dismiss()
            case .wrongPin:
                phase = .failed("The PIN didn't match. Try again.")
            case .alreadyInProgress:
                phase = .failed("The host is already pairing with another device.")
            case .failed(let message):
                phase = .failed(message)
            }
        }
    }
}
