import Foundation

/// Open-Meteo client. Weather numbers shown in the app come straight
/// from this response; the model never rewrites them.
struct WeatherService {
    enum WeatherError: LocalizedError {
        case badResponse
        var errorDescription: String? { "Weather could not be loaded." }
    }

    private let session = URLSession.shared

    func fetchWeather(
        latitude: Double,
        longitude: Double,
        locationName: String,
        unit: TemperatureUnit
    ) async throws -> WeatherSnapshot {
        let resolvedUnit = unit.resolved
        let unitParameter = resolvedUnit == .fahrenheit ? "fahrenheit" : "celsius"

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,weather_code"),
            URLQueryItem(name: "temperature_unit", value: unitParameter),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WeatherError.badResponse
        }
        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

        guard let current = decoded.current,
              let daily = decoded.daily,
              let high = daily.temperature2mMax.first,
              let low = daily.temperature2mMin.first
        else { throw WeatherError.badResponse }

        return WeatherSnapshot(
            locationName: locationName,
            latitude: latitude,
            longitude: longitude,
            temperature: current.temperature2m,
            apparentTemperature: current.apparentTemperature,
            high: high,
            low: low,
            precipitationProbability: daily.precipitationProbabilityMax.first ?? 0,
            conditionCode: daily.weatherCode.first ?? current.weatherCode,
            windSpeed: current.windSpeed10m,
            sunrise: daily.sunrise.first.flatMap(parseLocalTime),
            sunset: daily.sunset.first.flatMap(parseLocalTime),
            unitSymbol: resolvedUnit == .fahrenheit ? "°F" : "°C",
            practicalNote: nil
        )
    }

    /// Open-Meteo returns local wall-clock times like "2026-07-10T05:52".
    private func parseLocalTime(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = .current
        return formatter.date(from: string)
    }

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            let temperature2m: Double
            let apparentTemperature: Double
            let weatherCode: Int
            let windSpeed10m: Double

            enum CodingKeys: String, CodingKey {
                case temperature2m = "temperature_2m"
                case apparentTemperature = "apparent_temperature"
                case weatherCode = "weather_code"
                case windSpeed10m = "wind_speed_10m"
            }
        }

        struct Daily: Decodable {
            let temperature2mMax: [Double]
            let temperature2mMin: [Double]
            let precipitationProbabilityMax: [Int]
            let sunrise: [String]
            let sunset: [String]
            let weatherCode: [Int]

            enum CodingKeys: String, CodingKey {
                case temperature2mMax = "temperature_2m_max"
                case temperature2mMin = "temperature_2m_min"
                case precipitationProbabilityMax = "precipitation_probability_max"
                case sunrise, sunset
                case weatherCode = "weather_code"
            }
        }

        let current: Current?
        let daily: Daily?
    }
}
