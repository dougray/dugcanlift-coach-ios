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
            VStack(alignment: .leading, spacing: 24) {
                volumeChart
                fuelChart
                bodyweightChart
                oneRepMaxChart
                weekTable
                sessionLog
            }
            .padding()
        }
        .navigationTitle(client.name)
    }

    // MARK: - Training volume

    private var volumeChart: some View {
        let points = sortedDays.map { day -> (String, Double) in
            let volume = day.sets.reduce(0.0) { total, set in
                total + (set.weightLb ?? 0) * Double(set.reps ?? 0)
            }
            return (day.dayKey, volume)
        }
        return VStack(alignment: .leading) {
            Text("Training Volume").font(.headline)
            Chart(points, id: \.0) { point in
                BarMark(x: .value("Day", point.0), y: .value("Volume (lb)", point.1))
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
        return VStack(alignment: .leading) {
            Text("Fuel").font(.headline)
            Chart {
                ForEach(points, id: \.0) { point in
                    LineMark(x: .value("Day", point.0), y: .value("Calories", point.1))
                }
                if let goal = client.goal {
                    RuleMark(y: .value("Goal", goal.calories))
                        .foregroundStyle(.secondary)
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
        return VStack(alignment: .leading) {
            Text("Bodyweight").font(.headline)
            Chart(points, id: \.0) { point in
                LineMark(x: .value("Day", point.0), y: .value("Weight (lb)", point.1))
                PointMark(x: .value("Day", point.0), y: .value("Weight (lb)", point.1))
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

        return VStack(alignment: .leading, spacing: 12) {
            Text("Estimated 1RM").font(.headline)
            ForEach(byLift.keys.sorted(), id: \.self) { lift in
                let points = (byLift[lift] ?? []).map { dayKey, set -> (String, Double) in
                    let weight = set.weightLb ?? 0
                    let reps = Double(set.reps ?? 0)
                    let estimate = weight * (1 + reps / 30)   // Epley
                    return (dayKey, estimate)
                }
                VStack(alignment: .leading) {
                    Text(lift).font(.subheadline)
                    Chart(points, id: \.0) { point in
                        LineMark(x: .value("Day", point.0), y: .value("Est. 1RM (lb)", point.1))
                    }
                    .frame(height: 100)
                }
            }
        }
    }

    // MARK: - Week table

    private var weekTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weeks").font(.headline)
            ForEach(sortedDays) { day in
                HStack {
                    Text(day.dayKey)
                    Spacer()
                    if let name = day.sessionName { Text(name).foregroundStyle(.secondary) }
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Session log

    private var sessionLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions").font(.headline)
            ForEach(sortedDays.reversed()) { day in
                DisclosureGroup(day.sessionName ?? day.dayKey) {
                    ForEach(day.sets) { set in
                        Text("\(set.exerciseName): \(Int(set.weightLb ?? 0)) lb × \(set.reps ?? 0)")
                            .font(.caption)
                    }
                }
            }
        }
    }
}
