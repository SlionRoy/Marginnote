import SwiftUI
import CoreLocation
import MapKit

@main
struct CoordinateApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

@MainActor
final class LocationModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    @Published var status = "等待定位"
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    func start() {
        guard CLLocationManager.locationServicesEnabled() else { status = "请开启系统定位服务"; return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.startUpdatingLocation(); status = "定位中…"
        case .denied, .restricted: status = "请在设置中允许定位权限"
        @unknown default: status = "定位权限不可用"
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { start() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last, latest.horizontalAccuracy >= 0 else { return }
        location = latest
        status = "定位成功"
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { status = "定位失败：\(error.localizedDescription)" }
}

struct ContentView: View {
    @StateObject private var model = LocationModel()
    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671), span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
    var body: some View {
        NavigationStack {
            ScrollView {
              VStack(spacing: 16) {
                Map(coordinateRegion: $region, showsUserLocation: true)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("苹果地图，显示当前所在位置")
                HStack {
                    Button("地图居中") { centerOnUser() }
                        .buttonStyle(.bordered)
                        .disabled(model.location == nil)
                    Spacer()
                    if let loc = model.location {
                        Button("在苹果地图中打开") {
                            let item = MKMapItem(placemark: MKPlacemark(coordinate: loc.coordinate))
                            item.name = "我的当前位置"
                            item.openInMaps(launchOptions: nil)
                        }.buttonStyle(.bordered)
                    }
                }
                Image(systemName: "location.circle.fill").font(.system(size: 36)).foregroundStyle(.blue)
                Text(model.status).font(.headline)
                if let loc = model.location {
                    Group {
                        row("纬度", String(format: "%.7f", loc.coordinate.latitude))
                        row("经度", String(format: "%.7f", loc.coordinate.longitude))
                        row("水平精度", String(format: "±%.1f 米", loc.horizontalAccuracy))
                        row("海拔", loc.verticalAccuracy >= 0 ? String(format: "%.1f 米", loc.altitude) : "不可用")
                        row("速度", loc.speed >= 0 ? String(format: "%.1f 米/秒", loc.speed) : "不可用")
                        row("方向", loc.course >= 0 ? String(format: "%.1f°", loc.course) : "不可用")
                    }
                    Button("复制经纬度") {
                        UIPasteboard.general.string = String(format: "%.7f, %.7f", loc.coordinate.latitude, loc.coordinate.longitude)
                    }.buttonStyle(.borderedProminent)
                }
                Button("刷新定位") { model.start() }.buttonStyle(.bordered)
                Text("位置数据仅在本机处理，不会上传服务器。")
                    .font(.footnote).foregroundStyle(.secondary)
              }
              .padding(20)
            }
            .navigationTitle("当前坐标")
            .onAppear { model.start() }
            .onReceive(model.$location) { newLocation in
                guard let newLocation else { return }
                region.center = newLocation.coordinate
            }
        }
    }
    private func centerOnUser() {
        guard let loc = model.location else { return }
        region = MKCoordinateRegion(center: loc.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
    }
    private func row(_ name: String, _ value: String) -> some View {
        HStack { Text(name).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }
    }
}
