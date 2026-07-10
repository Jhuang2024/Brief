import CoreLocation
import Foundation

/// Resolves the coordinates and display name used for weather.
/// Falls back to a manual city, then to Berkeley, California.
final class LocationService: NSObject, CLLocationManagerDelegate {
    struct ResolvedLocation {
        var name: String
        var latitude: Double
        var longitude: Double
        var isFallback: Bool
    }

    static let berkeleyFallback = ResolvedLocation(
        name: "Berkeley, CA",
        latitude: 37.8715,
        longitude: -122.2730,
        isFallback: true
    )

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    /// Resolve according to preferences: current location, manual city, or Berkeley.
    func resolveLocation(preferences: UserPreferences) async -> ResolvedLocation {
        if preferences.useCurrentLocation {
            if let current = await currentLocation() {
                return current
            }
        }
        let manualCity = preferences.manualCity.trimmingCharacters(in: .whitespaces)
        if !manualCity.isEmpty, let manual = await geocodeCity(named: manualCity) {
            return manual
        }
        return Self.berkeleyFallback
    }

    private func currentLocation() async -> ResolvedLocation? {
        let status = await ensureAuthorization()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }

        do {
            let location = try await requestLocation()
            let name = await placemarkName(for: location) ?? "Current Location"
            return ResolvedLocation(
                name: name,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                isFallback: false
            )
        } catch {
            return nil
        }
    }

    private func ensureAuthorization() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    private func requestLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    private func placemarkName(for location: CLLocation) async -> String? {
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return nil
        }
        let city = placemark.locality ?? placemark.subAdministrativeArea
        let region = placemark.administrativeArea ?? placemark.country
        switch (city, region) {
        case let (city?, region?): return "\(city), \(region)"
        case let (city?, nil): return city
        case let (nil, region?): return region
        default: return nil
        }
    }

    private func geocodeCity(named city: String) async -> ResolvedLocation? {
        guard let placemark = try? await geocoder.geocodeAddressString(city).first,
              let location = placemark.location
        else { return nil }
        return ResolvedLocation(
            name: placemark.locality ?? city,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            isFallback: false
        )
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        authorizationContinuation?.resume(returning: manager.authorizationStatus)
        authorizationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        locationContinuation?.resume(returning: location)
        locationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
    }
}
