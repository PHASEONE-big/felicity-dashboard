import SwiftUI

struct WeatherScreen: View {
    @ObservedObject var weather: WeatherViewModel
    let openSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > 1000
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let forecast = weather.forecast, let location = weather.selectedLocation {
                            hero(forecast, location: location, wide: wide)
                            freshness
                            hourly(forecast)
                            if wide {
                                HStack(alignment: .top, spacing: 20) {
                                    week(forecast)
                                    conditions(forecast).frame(maxWidth: 320)
                                }
                            } else {
                                week(forecast)
                                conditions(forecast)
                            }
                            attribution
                        } else {
                            emptyState
                        }
                    }
                    .padding(proxy.size.width < 600 ? 18 : 28)
                    .frame(maxWidth: 1260)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .foregroundStyle(FelicityPalette.primary)
            .background(FelicityPalette.background.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .task { await weather.refresh() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back to energy dashboard")
            Text("WEATHER").font(.headline).tracking(1.5)
            Spacer()
            if weather.isLoading { ProgressView().tint(FelicityPalette.accent) }
            Button { Task { await weather.refresh(force: true) } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
            }
            .disabled(weather.isLoading || weather.selectedLocation == nil)
            .accessibilityLabel("Refresh weather")
            Button(action: openSettings) {
                Image(systemName: "mappin.and.ellipse").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Change weather location")
        }
        .foregroundStyle(FelicityPalette.accent)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(FelicityPalette.header)
    }

    private func hero(_ forecast: WeatherForecast, location: WeatherLocation, wide: Bool) -> some View {
        let condition = WeatherCondition(code: forecast.current.code, isDay: forecast.current.isDay)
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(location.name).font(.system(size: wide ? 34 : 29, weight: .semibold, design: .rounded))
                if !location.country.isEmpty {
                    Text(location.country).font(.subheadline).foregroundStyle(FelicityPalette.secondary)
                }
                Text(temperature(forecast.current.temperature))
                    .font(.system(size: wide ? 108 : 88, weight: .ultraLight, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                Text(condition.description).font(.title3.weight(.medium))
                if let day = localDays(forecast).first {
                    Text("High \(temperature(day.maximumTemperature)) · Low \(temperature(day.minimumTemperature))")
                        .font(.subheadline).foregroundStyle(FelicityPalette.secondary)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: condition.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: wide ? 112 : 76, weight: .light))
                .frame(minWidth: 80)
                .accessibilityHidden(true)
        }
        .padding(wide ? 30 : 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.10, green: 0.24, blue: 0.30), FelicityPalette.card], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 26)
        )
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.07)))
    }

    private var freshness: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: weather.isStale ? "clock.badge.exclamationmark" : "checkmark.circle")
                if let updated = weather.updatedAt {
                    Text("Updated \(updated.formatted(.dateTime.hour().minute()))\(weather.isStale ? " · saved forecast" : "")")
                } else {
                    Text(weather.isStale ? "Saved forecast" : "Forecast available")
                }
            }
            .foregroundStyle(weather.isStale ? FelicityPalette.warning : FelicityPalette.secondary)
            if !weather.error.isEmpty {
                Text(weather.error).foregroundStyle(FelicityPalette.warning)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hourly(_ forecast: WeatherForecast) -> some View {
        let hours = forecast.todayHours(at: Date())
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Today by hour", systemImage: "clock").font(.title3.weight(.semibold))
                Spacer()
                Text("Local time").font(.caption).foregroundStyle(FelicityPalette.secondary)
            }
            if hours.isEmpty {
                Text("No hourly forecast is available for today.")
                    .font(.subheadline).foregroundStyle(FelicityPalette.secondary).padding(.vertical, 24)
            } else {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 10) {
                            ForEach(hours, id: \.date) { hour in
                                hourCard(hour, timezone: forecast.timezoneID).id(hour.date)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onAppear {
                        if let current = hours.last(where: { $0.date <= Date() }) {
                            scroll.scrollTo(current.date, anchor: .leading)
                        }
                    }
                }
            }
        }
        .padding(20).weatherPanel()
    }

    private func hourCard(_ hour: WeatherHour, timezone: String) -> some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)!
        let isCurrent = calendar.isDate(hour.date, equalTo: Date(), toGranularity: .hour)
        return VStack(spacing: 17) {
            Text(isCurrent ? "Now" : localTime(hour.date, timezone: timezone))
                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? FelicityPalette.accent : FelicityPalette.secondary)
            Image(systemName: WeatherCondition(code: hour.code, isDay: hour.isDay ?? true).symbolName)
                .symbolRenderingMode(.multicolor).font(.system(size: 31)).frame(height: 36)
            Text(temperature(hour.temperature)).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
            HStack(spacing: 4) {
                Image(systemName: "drop.fill").font(.caption2)
                Text(hour.precipitationProbability.map { "\(Int($0.rounded()))%" } ?? "—")
            }
            .font(.caption).foregroundStyle(Color(red: 0.46, green: 0.72, blue: 1))
        }
        .padding(.vertical, 18).frame(width: 84)
        .background(isCurrent ? FelicityPalette.accent.opacity(0.12) : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(isCurrent ? FelicityPalette.accent.opacity(0.35) : .clear))
        .accessibilityElement(children: .combine)
    }

    private func localDays(_ forecast: WeatherForecast) -> [WeatherDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        let today = calendar.startOfDay(for: Date())
        return forecast.daily.filter { $0.date >= today }
    }

    private func week(_ forecast: WeatherForecast) -> some View {
        let days = Array(localDays(forecast).prefix(7))
        let low = days.map(\.minimumTemperature).min() ?? 0
        let high = days.map(\.maximumTemperature).max() ?? 1
        return VStack(alignment: .leading, spacing: 18) {
            Label("Next 7 days", systemImage: "calendar").font(.title3.weight(.semibold))
            ForEach(Array(days.enumerated()), id: \.element.date) { index, day in
                HStack(spacing: 12) {
                    Text(localDay(day.date, timezone: forecast.timezoneID))
                        .font(.subheadline.weight(.medium)).frame(width: 62, alignment: .leading)
                    Image(systemName: WeatherCondition(code: day.code, isDay: true).symbolName)
                        .symbolRenderingMode(.multicolor).font(.title3).frame(width: 32)
                    Text(day.precipitationProbability.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(.caption).foregroundStyle(Color(red: 0.46, green: 0.72, blue: 1)).frame(width: 35)
                    Text(temperature(day.minimumTemperature)).font(.subheadline).monospacedDigit()
                        .foregroundStyle(FelicityPalette.secondary).frame(width: 36, alignment: .trailing)
                    temperatureRange(minimum: day.minimumTemperature, maximum: day.maximumTemperature, low: low, high: high)
                        .frame(height: 5)
                    Text(temperature(day.maximumTemperature)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                .frame(minHeight: 43)
                .accessibilityElement(children: .combine)
                if index < days.count - 1 { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).weatherPanel()
    }

    private func temperatureRange(minimum: Double, maximum: Double, low: Double, high: Double) -> some View {
        GeometryReader { proxy in
            let span = max(1, high - low)
            let start = min(1, max(0, (minimum - low) / span))
            let end = min(1, max(start, (maximum - low) / span))
            Capsule().fill(.white.opacity(0.08))
                .overlay(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [Color.cyan.opacity(0.75), .orange], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * (end - start)))
                        .offset(x: proxy.size.width * start)
                }
        }
        .accessibilityHidden(true)
    }

    private func conditions(_ forecast: WeatherForecast) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Current conditions", systemImage: "slider.horizontal.3").font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 24) {
                conditionFact("Feels like", value: forecast.current.apparentTemperature.map(temperature) ?? "—", symbol: "thermometer.medium")
                conditionFact("Wind", value: forecast.current.windSpeed.map { "\(Int($0.rounded())) km/h" } ?? "—", symbol: "wind")
                conditionFact("Humidity", value: forecast.current.humidity.map { "\(Int($0.rounded()))%" } ?? "—", symbol: "humidity")
                conditionFact("Cloud cover", value: forecast.current.cloudCover.map { "\(Int($0.rounded()))%" } ?? "—", symbol: "cloud")
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).weatherPanel()
    }

    private func conditionFact(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(FelicityPalette.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
    }

    private var attribution: some View {
        Link(destination: URL(string: "https://open-meteo.com/")!) {
            HStack(spacing: 5) {
                Text("Weather data by Open-Meteo")
                Image(systemName: "arrow.up.right").font(.caption2)
            }
        }
        .font(.caption).foregroundStyle(FelicityPalette.secondary)
        .frame(maxWidth: .infinity).padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "cloud.sun").font(.system(size: 62, weight: .light)).foregroundStyle(FelicityPalette.accent)
            Text(weather.selectedLocation == nil ? "Choose your weather location" : "Loading the local forecast")
                .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text(weather.error.isEmpty ? "A local hourly forecast for today and the next seven days." : weather.error)
                .font(.subheadline).foregroundStyle(FelicityPalette.secondary).multilineTextAlignment(.center)
            if weather.isLoading { ProgressView().tint(FelicityPalette.accent) }
            Button(action: openSettings) { Label("Choose location", systemImage: "mappin.and.ellipse").padding(.horizontal, 20).padding(.vertical, 12) }
                .buttonStyle(.borderedProminent).tint(FelicityPalette.accent).foregroundStyle(FelicityPalette.background)
        }
        .frame(maxWidth: .infinity, minHeight: 420).padding(24).weatherPanel()
    }
}

struct WeatherLocationSettingsSection: View {
    @ObservedObject var weather: WeatherViewModel
    @State private var query = ""

    var body: some View {
        Section {
            if let selected = weather.selectedLocation {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected.name).font(.headline)
                        if !selected.country.isEmpty { Text(selected.country).font(.caption).foregroundStyle(.secondary) }
                    }
                } icon: { Image(systemName: "mappin.circle.fill") }
            }
            TextField("Search for a town or city", text: $query)
                .textInputAutocapitalization(.words).autocorrectionDisabled()
                .submitLabel(.search)
            if weather.isSearching { HStack { ProgressView(); Text("Searching locations…").font(.subheadline) } }
            if !weather.searchError.isEmpty { Text(weather.searchError).font(.caption).foregroundStyle(.orange) }
            ForEach(weather.searchResults) { location in
                Button {
                    weather.selectLocation(location)
                    query = ""
                    Task { await weather.refresh(force: true) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(location.name)
                            if !location.country.isEmpty { Text(location.country).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if weather.selectedLocation?.id == location.id { Image(systemName: "checkmark.circle.fill") }
                    }
                }
            }
        } header: {
            Text("Weather location")
        } footer: {
            Text("Choose a location manually. Forecasts are cached and refreshed periodically. Data: Open-Meteo.")
        }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 2 {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled else { return }
            }
            await weather.search(trimmed)
        }
    }
}

struct WeatherBadge: View {
    @ObservedObject var weather: WeatherViewModel
    var isNight = false
    var compact = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: weather.forecast.map { WeatherCondition(code: $0.current.code, isDay: $0.current.isDay).symbolName } ?? "cloud.sun")
                    .font(.system(size: compact ? 19 : 24, weight: .regular))
                if let forecast = weather.forecast {
                    Text(temperature(forecast.current.temperature)).font(compact ? .headline : .title3).monospacedDigit()
                } else if !compact {
                    Text("Weather").font(.subheadline)
                }
                if weather.isStale && weather.forecast != nil { Image(systemName: "clock").font(.caption2) }
            }
            .padding(.horizontal, compact ? 10 : 14).frame(minHeight: 42)
            .foregroundStyle(isNight ? Color.red : FelicityPalette.primary)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(weather.forecast.map { "Weather, \(temperature($0.current.temperature)), \(WeatherCondition(code: $0.current.code, isDay: $0.current.isDay).description)" } ?? "Choose weather location")
    }
}

struct ClockWeatherView: View {
    @ObservedObject var weather: WeatherViewModel
    let isNight: Bool

    var body: some View {
        if let forecast = weather.forecast {
            HStack(spacing: 10) {
                Image(systemName: WeatherCondition(code: forecast.current.code, isDay: forecast.current.isDay).symbolName)
                Text(temperature(forecast.current.temperature)).monospacedDigit()
                if let location = weather.selectedLocation { Text(location.name).lineLimit(1) }
                if weather.isStale { Image(systemName: "clock").font(.caption) }
            }
            .font(.system(size: 22, weight: .light, design: .rounded))
            .foregroundStyle(isNight ? Color.red : Color.white)
            .accessibilityElement(children: .combine)
        }
    }
}

private func temperature(_ value: Double) -> String {
    guard value.isFinite else { return "—°" }
    return "\(Int(value.rounded()))°"
}

private func localTime(_ date: Date, timezone: String) -> String {
    var style = Date.FormatStyle().hour().minute()
    style.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)!
    return date.formatted(style)
}

private func localDay(_ date: Date, timezone: String) -> String {
    let zone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    if calendar.isDate(date, inSameDayAs: Date()) { return "Today" }
    var style = Date.FormatStyle().weekday(.abbreviated)
    style.timeZone = zone
    return date.formatted(style)
}

private extension View {
    func weatherPanel() -> some View {
        background(FelicityPalette.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(FelicityPalette.secondary.opacity(0.1)))
    }
}
