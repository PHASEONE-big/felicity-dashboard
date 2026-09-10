import SwiftUI
import UIKit

@MainActor
final class EventsViewModel: ObservableObject {
    @Published private(set) var events: [ThreeEyeEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error = ""
    @Published var allCameras = false
    @Published var enabledClasses = Set(ThreeEyeEventClass.allCases)

    let cameraName: String?
    private let configuration: ThreeEyeConfiguration
    private let api: ThreeEyeAPI
    private var requestGeneration = 0

    init(configuration: ThreeEyeConfiguration, cameraName: String?, api: ThreeEyeAPI = ThreeEyeAPI()) {
        self.configuration = configuration
        self.cameraName = cameraName
        self.api = api
    }

    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(4))
        }
    }

    func toggle(_ eventClass: ThreeEyeEventClass) async {
        if enabledClasses.contains(eventClass) {
            guard enabledClasses.count > 1 else { return }
            enabledClasses.remove(eventClass)
        } else {
            enabledClasses.insert(eventClass)
        }
        await refresh()
    }

    func toggleScope() async {
        allCameras.toggle()
        await refresh()
    }

    func refresh() async {
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = events.isEmpty
        do {
            let loaded = try await api.events(
                configuration: configuration,
                camera: allCameras ? nil : cameraName,
                classes: enabledClasses,
                limit: 54
            )
            guard generation == requestGeneration else { return }
            events = loaded
            error = ""
        } catch {
            guard generation == requestGeneration else { return }
            self.error = error.localizedDescription
        }
        if generation == requestGeneration { isLoading = false }
    }
}

struct EventsView: View {
    let configuration: ThreeEyeConfiguration
    let backLabel: String
    @ObservedObject var repository: CameraRepository
    @ObservedObject var preferences: CameraPreferences
    @StateObject private var model: EventsViewModel
    @State private var selectedEvent: ThreeEyeEvent?
    @Environment(\.dismiss) private var dismiss

    init(configuration: ThreeEyeConfiguration, cameraName: String?, backLabel: String, repository: CameraRepository, preferences: CameraPreferences) {
        self.configuration = configuration
        self.backLabel = backLabel
        self.repository = repository
        self.preferences = preferences
        _model = StateObject(wrappedValue: EventsViewModel(configuration: configuration, cameraName: cameraName))
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = max(2, min(4, Int(proxy.size.width / 290)))
            VStack(spacing: 0) {
                eventHeader(compact: proxy.size.width < 920)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                        ForEach(model.events) { event in
                            Button { selectedEvent = event } label: {
                                EventCard(event: event, configuration: configuration)
                            }
                            .buttonStyle(PressScaleButtonStyle())
                        }
                    }
                    .padding(14)
                }
                .scrollBounceBehavior(.basedOnSize)
                .overlay {
                    if model.isLoading {
                        ProgressView("Loading events…")
                            .controlSize(.large)
                            .padding(24)
                            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
                    } else if model.events.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: model.error.isEmpty ? "rectangle.stack.badge.person.crop" : "wifi.slash")
                                .font(.system(size: 38, weight: .medium))
                            Text(model.error.isEmpty ? "No matching events" : "3ye unavailable")
                                .font(.headline)
                            if !model.error.isEmpty {
                                Text(model.error)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.65))
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(28)
                    }
                }
            }
            .background(eventBackground.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .task { await model.run() }
        .fullScreenCover(item: $selectedEvent) { event in
            if let camera = camera(for: event) {
                ArchiveView(camera: camera, event: event, backLabel: "EVENTS", repository: repository, preferences: preferences)
            }
        }
    }

    private func camera(for event: ThreeEyeEvent) -> CameraDescriptor? {
        let wanted = normalized(event.camera)
        return repository.cameras.first(where: {
            let name = normalized($0.name), source = normalized($0.sourceToken)
            return name == wanted || source == wanted || name.contains(wanted) || wanted.contains(name)
        }) ?? repository.selected
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    @ViewBuilder
    private func eventHeader(compact: Bool) -> some View {
        if compact {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    CameraBarButton(title: backLabel, systemImage: "chevron.left") { dismiss() }
                    Text("3YE · \(model.allCameras ? "ALL CAMERAS" : model.cameraName ?? "EVENTS")")
                        .font(.headline.bold())
                        .foregroundStyle(.cyan)
                        .lineLimit(1)
                    Spacer()
                    EventScopeButton(allCameras: model.allCameras) { Task { await model.toggleScope() } }
                }
                filterButtons
            }
            .padding(10)
            .background(eventHeaderColor)
        } else {
            HStack(spacing: 10) {
                CameraBarButton(title: backLabel, systemImage: "chevron.left") { dismiss() }
                Text("3YE · \(model.allCameras ? "ALL CAMERAS" : model.cameraName ?? "EVENTS")")
                    .font(.headline.bold())
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
                Spacer(minLength: 8)
                EventScopeButton(allCameras: model.allCameras) { Task { await model.toggleScope() } }
                filterButtons
            }
            .padding(10)
            .frame(minHeight: 66)
            .background(eventHeaderColor)
        }
    }

    private var filterButtons: some View {
        HStack(spacing: 8) {
            ForEach(ThreeEyeEventClass.allCases, id: \.self) { eventClass in
                let enabled = model.enabledClasses.contains(eventClass)
                Button { Task { await model.toggle(eventClass) } } label: {
                    Label(eventClass.title, systemImage: eventClass.systemImage)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 42)
                        .foregroundStyle(enabled ? .white : .secondary)
                        .background(enabled ? Color.cyan.opacity(0.18) : Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(enabled ? .cyan : .gray.opacity(0.35), lineWidth: 1.2))
                }
                .buttonStyle(PressScaleButtonStyle())
            }
        }
    }
}

private struct EventScopeButton: View {
    let allCameras: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(allCameras ? "ALL CAMERAS" : "THIS CAMERA")
                .font(.caption.bold())
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 42)
        }
        .buttonStyle(HeaderButtonStyle())
    }
}

private struct EventCard: View {
    let event: ThreeEyeEvent
    let configuration: ThreeEyeConfiguration

    var body: some View {
        VStack(spacing: 0) {
            ThreeEyeImage(url: event.thumbnailURL, configuration: configuration)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(.black)
            VStack(spacing: 5) {
                HStack {
                    Text(event.capturedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? event.capturedAtRaw)
                        .font(.subheadline.bold().monospacedDigit())
                        .lineLimit(1)
                    Spacer()
                    Label(event.eventClass.title, systemImage: event.eventClass.systemImage)
                        .font(.caption.bold())
                        .foregroundStyle(.cyan)
                }
                HStack {
                    Text(event.camera)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if event.confidence > 0 {
                        Text((event.confidence > 1 ? event.confidence / 100 : event.confidence).formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 58)
        }
        .foregroundStyle(.white)
        .background(eventCardColor, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cyan.opacity(0.24), lineWidth: 1))
    }
}

private struct ThreeEyeImage: View {
    let url: URL?
    let configuration: ThreeEyeConfiguration
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .tint(.cyan)
            }
        }
        .task(id: url) {
            guard let url else { failed = true; return }
            do {
                let data = try await ThreeEyeImageStore.shared.data(for: url, configuration: configuration)
                image = UIImage(data: data)
                failed = image == nil
            } catch {
                failed = true
            }
        }
    }
}

private let eventBackground = Color(red: 7 / 255, green: 17 / 255, blue: 15 / 255)
private let eventHeaderColor = Color(red: 14 / 255, green: 48 / 255, blue: 43 / 255)
private let eventCardColor = Color(red: 13 / 255, green: 39 / 255, blue: 35 / 255)
