import AppIntents
import CommuteCore
import SwiftUI
import WidgetKit

/// A saved commute on the Home Screen. A tap opens it in the app with the arrival time ready to be chosen.
struct CommuteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.commute, intent: SelectCommuteIntent.self, provider: CommuteTimelineProvider()) { entry in
            CommuteWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Commute")
        .description("Open one of your commutes and choose when to arrive.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// MARK: Choosing the commute

nonisolated struct CommuteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Commute"
    static let defaultQuery = CommuteQuery()

    let id: String
    let name: String
    let detail: String

    init(_ commute: CommuteSummary) {
        id = commute.id
        name = commute.name
        detail = commute.route
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }
}

nonisolated struct CommuteQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CommuteEntity] {
        CommuteSummary.loadAll().filter { identifiers.contains($0.id) }.map(CommuteEntity.init)
    }

    func suggestedEntities() async throws -> [CommuteEntity] {
        CommuteSummary.loadAll().map(CommuteEntity.init)
    }

    /// A widget dropped on the Home Screen shows the first commute until another is picked.
    func defaultResult() async -> CommuteEntity? {
        CommuteSummary.loadAll().first.map(CommuteEntity.init)
    }
}

struct SelectCommuteIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Commute"
    static let description = IntentDescription("Choose the commute this widget opens.")

    @Parameter(title: "Commute")
    var commute: CommuteEntity?
}

// MARK: Timeline

nonisolated struct CommuteEntry: TimelineEntry {
    let date: Date
    /// Nil when no commute has been saved, or the one chosen has since been deleted.
    var commute: CommuteSummary?
    /// There are commutes; this widget's has gone.
    var hasOthers = false
}

/// Nothing here moves with the clock: the app redraws the widget whenever its commutes change.
nonisolated struct CommuteTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CommuteEntry {
        CommuteEntry(date: .now, commute: .sample)
    }

    func snapshot(for configuration: SelectCommuteIntent, in context: Context) async -> CommuteEntry {
        let entry = entry(for: configuration)
        return entry.commute == nil && context.isPreview ? CommuteEntry(date: .now, commute: .sample) : entry
    }

    func timeline(for configuration: SelectCommuteIntent, in context: Context) async -> Timeline<CommuteEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: SelectCommuteIntent) -> CommuteEntry {
        let commutes = CommuteSummary.loadAll()
        let chosen = configuration.commute.flatMap { entity in commutes.first { $0.id == entity.id } }
        // Until one is chosen the widget stands for the first, as the picker's default says it will.
        return CommuteEntry(date: .now, commute: chosen ?? (configuration.commute == nil ? commutes.first : nil), hasOthers: !commutes.isEmpty)
    }
}

extension CommuteSummary {
    /// "Home to Office", or "To Office" from wherever the rider is.
    nonisolated var route: String {
        origin.map { "\($0) to \(destination)" } ?? "To \(destination)"
    }

    nonisolated static let sample = CommuteSummary(id: "sample", name: "Morning Commute", origin: "Home", destination: "Office",
                                                   symbol: "tram.fill", arriveByMinutes: 9 * 60)
}

// MARK: Views

private struct CommuteWidgetView: View {
    let entry: CommuteEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let commute = entry.commute {
            Group {
                switch family {
                case .accessoryRectangular: lockScreen(commute)
                case .systemMedium: medium(commute)
                default: small(commute)
                }
            }
            .widgetURL(AppLink.commute(id: commute.id).url)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the commute to choose an arrival time")
        } else {
            empty
        }
    }

    private func small(_ commute: CommuteSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            tile(commute)
            Spacer(minLength: 6)
            Text(commute.name)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text(commute.route)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            arriveBy(commute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func medium(_ commute: CommuteSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                tile(commute)
                Spacer(minLength: 6)
                Text(commute.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(commute.route)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                if let time = commute.arriveBy {
                    Text("Arrive By")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(time.next(), style: .time)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Label(commute.arriveBy == nil ? "Choose Arrival Time" : "Change", systemImage: "target")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.tint.opacity(0.15), in: .capsule)
                    .widgetAccentable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lockScreen(_ commute: CommuteSummary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(commute.name, systemImage: commute.symbol)
                .font(.headline)
                .widgetAccentable()
            Text(commute.route)
            arriveByText(commute)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tile(_ commute: CommuteSummary) -> some View {
        Image(systemName: commute.symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Color.accentColor.gradient, in: .rect(cornerRadius: 10, style: .continuous))
            .widgetAccentable()
            .accessibilityHidden(true)
    }

    private func arriveBy(_ commute: CommuteSummary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "target")
            arriveByText(commute)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tint)
        .lineLimit(1)
        .widgetAccentable()
    }

    private func arriveByText(_ commute: CommuteSummary) -> Text {
        if let time = commute.arriveBy {
            Text("Arrive by \(time.next(), style: .time)")
        } else {
            Text("Choose arrival time")
        }
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(entry.hasOthers ? "Commute Removed" : "No Commutes")
                .font(.headline)
            Text(entry.hasOthers ? "Touch and hold to choose another." : "Save a commute in the app to see it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
