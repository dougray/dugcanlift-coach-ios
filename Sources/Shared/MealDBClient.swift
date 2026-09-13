import Foundation

/// A dish imported from TheMealDB: shape only, no nutrition.
struct ImportedRecipe: Equatable, Identifiable {
    let id = UUID()
    let name: String
    let ingredients: [String]
    let steps: [String]
}

/// TheMealDB carries recipes -- name, ingredients, method -- and no nutrition
/// at all. USDA carries nutrition and no recipes. So an import takes the shape
/// of the dish from one and costs it, as far as it can, from the other.
///
/// The only networked thing in Coach. The fetcher is injected so the tests
/// never leave the machine.
struct MealDBClient {
    typealias Fetch = (URL) async throws -> Data

    private static let base = "https://www.themealdb.com/api/json/v1/1"
    private let fetch: Fetch

    init(fetch: @escaping Fetch = MealDBClient.urlSessionFetch) {
        self.fetch = fetch
    }

    static func urlSessionFetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func search(_ query: String) async throws -> [ImportedRecipe] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
        guard let url = URL(string: "\(Self.base)/search.php?s=\(encoded)") else {
            throw URLError(.badURL)
        }
        let data = try await fetch(url)
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.meals ?? []).map(Self.recipe)
    }

    private struct Response: Decodable {
        let meals: [[String: String?]]?
    }

    /// TheMealDB ships 20 fixed ingredient/measure slots and leaves the unused
    /// ones empty, so the mapping counts rather than iterates keys.
    private static func recipe(from meal: [String: String?]) -> ImportedRecipe {
        var ingredients: [String] = []
        for i in 1...20 {
            let name = (meal["strIngredient\(i)"] ?? nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { continue }
            let measure = (meal["strMeasure\(i)"] ?? nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ingredients.append(measure.isEmpty ? name : "\(measure) \(name)")
        }
        let steps = ((meal["strInstructions"] ?? nil) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ImportedRecipe(
            name: (meal["strMeal"] ?? nil) ?? "Imported recipe",
            ingredients: ingredients,
            steps: steps)
    }
}

private extension CharacterSet {
    /// `.urlQueryAllowed` permits `&` and `=`, which a dish name can contain.
    static let urlQueryValueAllowed = CharacterSet.urlQueryAllowed
        .subtracting(CharacterSet(charactersIn: "&=+?"))
}
