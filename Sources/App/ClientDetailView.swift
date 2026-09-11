import SwiftUI
import SwiftData
import Charts

struct ClientDetailView: View {
    let client: Client

    private var sortedDays: [TrainingDay] {
        client.trainingDays.sorted { $0.dayKey < $1.dayKey }
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
            return (day.dayKey, volume)
        }
        return LiftCard(title: "Training Volume") {
            Chart(points, id: \.0) { point in
                BarMark(x: .value("Day", point.0), y: .value("Volume (lb)", point.1))
                    .foregroundStyle(Theme.accent)
            }
            .frame(height: 180)
        }
    }

    // MARK: - Fuel vs. goal

    private var fuelChart: some View {
        let points = sortedDays.compactMap { day -> (String, Double)? in
            guard let calories = day.foodCalories else { return nil }
            return (day.dayKey, calories)
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
            return (day.dayKey, weight)
        }
        return LiftCard(title: "Bodyweight") {
            Chart(points, id: \.0) { point in
                LineMark(x: .value("Day", point.0), y: .value("Weight (lb)", point.1))
                    .foregroundStyle(Theme.accent)
                PointMark(x: .value("Day", point.0), y: .value("Weight (lb)", point.1))
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
        }, by: { $0.1.exerciseName })

        return LiftCard(title: "Estimated 1RM") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(byLift.keys.sorted(), id: \.self) { lift in
                    let points = (byLift[lift] ?? []).map { dayKey, set -> (String, Double) in
                        let weight = set.weightLb ?? 0
                        let reps = Double(set.reps ?? 0)
                        let estimate = weight * (1 + reps / 30)   // Epley
                        return (dayKey, estimate)
                    }
                    VStack(alignment: .leading) {
                        Text(lift).font(.subheadline).foregroundStyle(Theme.textSecondary)
                        Chart(points, id: \.0) { point in
                            LineMark(x: .value("Day", point.0), y: .value("Est. 1RM (lb)", point.1))
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
                ForEach(sortedDays.reversed()) { day in
                    DisclosureGroup(day.sessionName ?? day.dayKey) {
                        ForEach(day.sets) { set in
                            Text("\(set.exerciseName): \(Int(set.weightLb ?? 0)) lb × \(set.reps ?? 0)")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
                }
            }
        }
    }
}
