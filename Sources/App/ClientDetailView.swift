import SwiftUI
import SwiftData
import Charts
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
                    DisclosureGroup {
                        ForEach(day.sets) { set in
                            Text("\(set.exerciseName): \(ClientDisplay.weightWithUnit(lb: set.weightLb, unit: unit)) × \(set.reps ?? 0)")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(day.dayKey)
                            if let name = day.sessionName {
                                Text(name).font(.caption).foregroundStyle(Theme.textSecondary)
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
