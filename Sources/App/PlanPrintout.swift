import UIKit
import LiftCore

/// A client's week on paper: the days that have something booked, each
/// workout's exercises and what they ask for, read the way Coach's own
/// workout cards read them (`PrescriptionText.summary`). For the client who
/// wants it printed or kept as a PDF rather than imported into LIFT.
///
/// The lines are a value with no view in them, so `PlanPrintoutTests` can pin
/// what is on the page; `pdf` only lays them out.
enum PlanPrintout {
    struct Exercise: Equatable {
        let name: String
        let prescription: String
        let note: String?
    }

    struct Workout: Equatable {
        let name: String
        let exercises: [Exercise]
    }

    struct Day: Equatable {
        let dayKey: String
        let workouts: [Workout]
    }

    /// Days in order, only those with a booking; a booking whose template has
    /// been deleted reads "Removed workout", as the week grid says it.
    static func days(weekDays: [String], sessions: [ScheduledSession], routines: [Routine],
                     sides: PrescriptionSides) -> [Day] {
        weekDays.compactMap { day in
            let booked = sessions.filter { $0.dayKey == day }
            guard !booked.isEmpty else { return nil }
            return Day(dayKey: day, workouts: booked.map { session in
                guard let routine = routines.first(where: { $0.id == session.routineID }) else {
                    return Workout(name: "Removed workout", exercises: [])
                }
                return Workout(name: routine.name, exercises: routine.orderedExercises.map { exercise in
                    Exercise(name: exercise.displayName,
                             prescription: PrescriptionText.summary(exercise, sides: sides),
                             note: exercise.note.flatMap { $0.isEmpty ? nil : $0 })
                })
            })
        }
    }

    /// "Mon 26 Oct", in the reader's locale.
    static func dayTitle(_ dayKey: String, locale: Locale = .current) -> String {
        guard let date = DayKey.date(from: dayKey) else { return dayKey }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale))
    }

    static func fileName(clientName: String, weekStart: String) -> String {
        let safe = clientName.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined()
        return "\(safe.isEmpty ? "Plan" : safe) – week of \(weekStart).pdf"
    }

    // MARK: - The page

    /// US Letter, which A4 printers also take without cropping a margin this
    /// wide. Text only, black on white whatever the app's appearance: it is
    /// for paper.
    static func pdf(clientName: String, weekStart: String, coachName: String?, days: [Day]) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 54
        let width = page.width - margin * 2
        let renderer = UIGraphicsPDFRenderer(bounds: page)

        let title = UIFont.systemFont(ofSize: 20, weight: .bold)
        let heading = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let workout = UIFont.systemFont(ofSize: 12, weight: .semibold)
        let body = UIFont.systemFont(ofSize: 11)
        let small = UIFont.systemFont(ofSize: 10)

        var blocks: [(NSAttributedString, CGFloat)] = []
        func add(_ text: String, _ font: UIFont, color: UIColor = .black, indent: CGFloat = 0,
                 before: CGFloat = 0) {
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.paragraphSpacingBefore = before
            blocks.append((NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]), before))
        }

        add(clientName, title)
        add("Week of \(dayTitle(weekStart))" + (coachName.map { " · from \($0)" } ?? ""), small,
            color: .darkGray)
        if days.isEmpty { add("Nothing is booked this week.", body, before: 12) }
        for day in days {
            add(dayTitle(day.dayKey), heading, before: 16)
            for item in day.workouts {
                add(item.name, workout, before: 6)
                for exercise in item.exercises {
                    add("\(exercise.name): \(exercise.prescription)", body, indent: 12, before: 2)
                    if let note = exercise.note { add(note, small, color: .darkGray, indent: 24) }
                }
            }
        }

        return renderer.pdfData { context in
            context.beginPage()
            var y = margin
            for (text, _) in blocks {
                let height = ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                    context: nil).height)
                if y + height > page.height - margin {
                    context.beginPage()
                    y = margin
                }
                text.draw(with: CGRect(x: margin, y: y, width: width, height: height),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                y += height
            }
        }
    }
}
