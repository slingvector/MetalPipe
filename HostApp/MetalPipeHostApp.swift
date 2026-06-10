//
//  MetalPipeHostApp.swift
//  MetalPipeHost (iOS)
//
//  The host app exists for two reasons only:
//
//   1. To ship and launch the broadcast extension
//      (RPSystemBroadcastPickerView).
//   2. To trigger the Local Network permission prompt. This is a
//      critical real-world gotcha: the prompt CANNOT be shown from
//      inside a broadcast extension. If the user never grants it,
//      the extension's Bonjour browse silently finds nothing and the
//      stream "just doesn't work". So we run a throwaway browse here,
//      in the full app, where iOS can show the dialog.
//

import SwiftUI
import ReplayKit
import Network
import Combine


@main
struct MetalPipeHostApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var permissionPrimer = LocalNetworkPrimer()

    var body: some View {
        VStack(spacing: 24) {
            Text("MetalPipe")
                .font(.largeTitle.bold())

            Text("1. Open the MetalPipe Receiver on your Mac\n2. Tap the button below and choose MetalPipe\n3. Tap Start Broadcast")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            BroadcastPickerView()
                .frame(width: 80, height: 80)

            if permissionPrimer.foundReceiver {
                Label("Receiver found on network", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Searching for receiver…", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear { permissionPrimer.start() }
    }
}

/// Wraps the system broadcast picker. IMPORTANT: set
/// `preferredExtension` to your extension's real bundle identifier
/// after you create the targets in Xcode.
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        // TODO: replace with your extension bundle id, e.g.
        // "com.slingvector.MetalPipe.BroadcastExtension"
        picker.preferredExtension = "com.anuj.iitr.MetalPipeHost.BroadcastExtension"
        picker.showsMicrophoneButton = false
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// Runs a Bonjour browse from the full app so iOS shows the
/// Local Network permission dialog. Doubles as a useful
/// "is the Mac receiver up?" indicator.
final class LocalNetworkPrimer: ObservableObject {
    @Published var foundReceiver = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(
            for: .bonjour(type: MetalPipeConfig.bonjourServiceType, domain: nil),
            using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { self?.foundReceiver = !results.isEmpty }
        }
        b.start(queue: .main)
        browser = b
    }
}
