import SwiftUI
import SwiftData
import Charts
import MapKit
import LiftCore

struct ClientDetailView: View {
    let client: Client

    private var sortedDays: [TrainingDay] {
        client.trainingDays.sorted { $0.dayKey < $1.dayKey }
    }

    /// Display only. Storage, the wire format and every statistic stay in
    /// pounds — see `ClientDisplay`.
    private var unit: String { client.displayUnit }

    /// Only days that actually hold sets. A client who weighs in daily but
    /// trains elsewhere used to produce a run of rows that expanded to
    /// nothing.
    private var sessionDays: [TrainingDay] {
        ClientDisplay.sessionDays(client.trainingDays)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                volumeChart
                fuelChart
                bodyweightChart
                oneRepMaxChart
                outdoorSection
                weekTable
                sessionLog
            }
            .padding()
        }
        .liftScreen()
        .background(Theme.background)
        .navigationTitle(client.name)
    }

    // MARK: - Training volume

    private var volumeChart: some View {
        let points = sortedDays.map { day -> (String, Double) in
            let volume = day.sets.reduce(0.0) { total, set in
                guard !set.isWarmup else { return total }
                return total + (set.weightLb ?? 0) * Double(set.reps ?? 0)
            }
            return (day.dayKey, ClientDisplay.weightValue(lb: volume, unit: unit))
        }
        return LiftCard(title: "Training Volume") {
            Chart(points, id: \.0) { point in
                BarMark(x: .value("Day", point.0), y: .value("Volume (\(unit))", point.1))
                    .foregroundStyle(Theme.accent)
            }
            .frame(height: 180)
        }
    }

    // MARK: - Fuel vs. goal

    private var fuelChart: some View {
        let points = sortedDays.compactMap { day -> (String, Double)? in
            if let calories = day.foodCalories { return (day.dayKey, calories) }
            guard !day.foodEntries.isEmpty else { return nil }
            let total = day.foodEntries.reduce(0.0) { $0 + $1.calories }
            return (day.dayKey, total)
        }
        return LiftCard(title: "Fuel") {
            Chart {
                ForEach(points, id: \.0) { point in
                    LineMark(x: .value("Day", point.0), y: .value("Calories", point.1))
                        .foregroundStyle(Theme.accent)
                }
                if let goal = client.goal {
                    // Reference line, not the data itself: hairline keeps it
                    // legible as "the goal" without competing with the
                    // accent-colored data line, matching how MacroProgressRow
                    // uses hairline for its background track.
                    RuleMark(y: .value("Goal", goal.calories))
                        .foregroundStyle(Theme.hairline)
                }
            }
            .frame(height: 180)
        }
    }

    // MARK: - Bodyweight trend

    private var bodyweightChart: some View {
        let points = sortedDays.compactMap { day -> (String, Double)? in
            guard let weight = day.bodyweightLb else { return nil }
            return (day.dayKey, ClientDisplay.weightValue(lb: weight, unit: unit))
        }
        return LiftCard(title: "Bodyweight") {
            Chart(points, id: \.0) { point in
                LineMark(x: .value("Day", point.0), y: .value("Weight (\(unit))", point.1))
                    .foregroundStyle(Theme.accent)
                PointMark(x: .value("Day", point.0), y: .value("Weight (\(unit))", point.1))
                    .foregroundStyle(Theme.accent)
            }
            .frame(height: 180)
        }
    }

    // MARK: - Per-lift estimated 1RM (Epley formula, matching LIFT's own convention)

    private var oneRepMaxChart: some View {
        let byLift = Dictionary(grouping: sortedDays.flatMap { day in
            day.sets.filter { !$0.isWarmup && $0.weightLb != nil && $0.reps != nil && $0.reps! > 0 }
                .map { (day.dayKey, $0) }
        }, by: { ClientDisplay.liftKey(name: $0.1.exerciseName, equipment: $0.1.equipment) })

        return LiftCard(title: "Estimated 1RM") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(byLift.keys.sorted(), id: \.self) { lift in
                    let points = (byLift[lift] ?? []).map { dayKey, set -> (String, Double) in
                        let weight = set.weightLb ?? 0
                        let reps = Double(set.reps ?? 0)
                        let estimate = weight * (1 + reps / 30)   // Epley
                        return (dayKey, ClientDisplay.weightValue(lb: estimate, unit: unit))
                    }
                    VStack(alignment: .leading) {
                        Text(ClientDisplay.liftDisplayName(key: lift))
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                        Chart(points, id: \.0) { point in
                            LineMark(x: .value("Day", point.0), y: .value("Est. 1RM (\(unit))", point.1))
                                .foregroundStyle(Theme.accent)
                        }
                        .frame(height: 100)
                    }
                }
            }
        }
    }

    // MARK: - Outdoor

    /// Miles or kilometres, following the client's weight unit as LIFT does.
    private var distanceUnit: String { OutdoorDisplay.distanceUnit(weightUnit: unit) }

    /// Days with a run, walk or hike, newest first -- the ten most recent.
    private var recentOutdoorDays: [TrainingDay] {
        Array(sortedDays.reversed()
            .filter { !OutdoorDisplay.activities($0.outdoor).isEmpty }
            .prefix(10))
    }

    /// Shown only when there is something in it, as on the web.
    @ViewBuilder
    private var outdoorSection: some View {
        let route = client.lastRoute
        let points = OutdoorDisplay.routePoints(route)
        let bests = OutdoorDisplay.bests(client.outdoorBests)
        let recent = recentOutdoorDays

        if points != nil || bests != nil || !recent.isEmpty {
            Text("Outdoor")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 4)

            if let route, let points {
                let stats = OutdoorDisplay.routeStats(route, unit: distanceUnit)
                LiftCard(title: "Last route") {
                    VStack(alignment: .leading, spacing: 10) {
                        ClientRouteMap(points: points)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        HStack {
                            Text(OutdoorDisplay.typeLabel(route.type) ?? "")
                                .foregroundStyle(Theme.textPrimary)
                            Text(Date(timeIntervalSince1970: TimeInterval(route.startedAtEpochSec))
                                .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                        }
                        .font(.system(size: 15, weight: .semibold))

                        HStack(spacing: 0) {
                            outdoorStat("Distance", stats.distance)
                            outdoorStat("Time", stats.time)
                            outdoorStat("Pace", stats.pace)
                        }

                        Text(OutdoorDisplay.trimNote)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            if let bests {
                LiftCard(title: "Personal bests") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(bests, id: \.type) { best in
                            let stats = OutdoorDisplay.bestStats(best, unit: distanceUnit)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(OutdoorDisplay.bestHeading(best))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                HStack(spacing: 0) {
                                    outdoorStat("Farthest", stats.farthest)
                                    outdoorStat("Longest", stats.longest)
                                    outdoorStat("Fastest pace", stats.fastest)
                                }
                            }
                        }
                    }
                }
            }

            if !recent.isEmpty {
                LiftCard(title: "Recent") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(recent) { day in
                            ForEach(Array(OutdoorDisplay.activities(day.outdoor).enumerated()), id: \.offset) { _, activity in
                                HStack {
                                    Text("\(day.dayKey) · \(OutdoorDisplay.typeLabel(activity.type) ?? "")")
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text(OutdoorDisplay.activityLine(activity, unit: distanceUnit))
                                        .foregroundStyle(Theme.textSecondary)
                                        .monospacedDigit()
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }

    private func outdoorStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Week table

    private var weekTable: some View {
        LiftCard(title: "Weeks") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sortedDays) { day in
                    HStack {
                        Text(day.dayKey).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if let name = day.sessionName { Text(name).foregroundStyle(Theme.textSecondary) }
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Session log

    private var sessionLog: some View {
        LiftCard(title: "Sessions") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sessionDays.reversed()) { day in
                    // The date leads, always. A day named "Push Day" used to
                    // lose its date entirely, leaving no way to tell when it
                    // happened without expanding it.
                    let outdoor = OutdoorDisplay.activities(day.outdoor)
                    DisclosureGroup {
                        ForEach(day.sets) { set in
                            Text("\(set.exerciseName): \(ClientDisplay.weightWithUnit(lb: set.weightLb, unit: unit)) × \(set.reps ?? 0)")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        ForEach(Array(outdoor.enumerated()), id: \.offset) { _, activity in
                            Text("\(OutdoorDisplay.typeLabel(activity.type) ?? ""): \(OutdoorDisplay.activityLine(activity, unit: distanceUnit))")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(day.dayKey)
                            if let name = day.sessionName {
                                Text(name).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            if !outdoor.isEmpty {
                                Text(OutdoorDisplay.daySummary(outdoor, unit: distanceUnit))
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
                }
            }
        }
    }
}

/// A client's last route on a map that does not move, drawn as LIFT iOS draws
/// its own Last route card. Scrolling the client screen must scroll it.
///
/// The polyline arrives already trimmed of its first and last 200 m by the
/// client's app; nothing here trims or extends it.
private struct ClientRouteMap: View {
    let points: [OutdoorShareCoordinate]

    var body: some View {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        Map(initialPosition: .automatic, interactionModes: []) {
            MapPolyline(coordinates: coordinates)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if let start = coordinates.first {
                Annotation("Start", coordinate: start, anchor: .center) {
                    Circle().fill(Theme.accentSecondary).frame(width: 10, height: 10)
                }
                .annotationTitles(.hidden)
            }
            if let end = coordinates.last {
                Annotation("Finish", coordinate: end, anchor: .center) {
                    Circle().fill(Theme.accent).frame(width: 12, height: 12)
                }
                .annotationTitles(.hidden)
            }
        }
        .allowsHitTesting(false)
    }
}
