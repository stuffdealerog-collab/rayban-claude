#if DEBUG
import MWDATMockDevice
import SwiftUI

/// Виртуальные очки из MockDeviceKit — проверка без настоящих Ray-Ban Meta (в том числе в симуляторе).
struct MockGlassesSection: View {
    @State private var isEnabled = MockDeviceKit.shared.isEnabled
    @State private var error: String?

    var body: some View {
        Section {
            if isEnabled {
                Button("Убрать виртуальные очки", role: .destructive) {
                    MockDeviceKit.shared.disable()
                    isEnabled = false
                }
            } else {
                Button("Подключить виртуальные очки") {
                    pair()
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Отладка")
        } footer: {
            Text("MockDeviceKit имитирует Ray-Ban Meta: регистрация и разрешения выдаются сразу. На iPhone «камерой очков» служит задняя камера телефона, в симуляторе — тестовый ролик и фото.")
        }
    }

    private func pair() {
        let kit = MockDeviceKit.shared
        kit.enable()
        do {
            let device = try kit.pairGlasses(model: .rayBanMeta)
            device.powerOn()
            device.unfold()
            device.don()
            let camera = device.services.camera
            if let photo = Bundle.main.url(forResource: "mock_photo", withExtension: "jpg") {
                camera.setCapturedImage(fileURL: photo)
            }
            #if targetEnvironment(simulator)
            // В симуляторе нет камеры — видеопоток из ролика (как в UI-тестах примера Meta).
            if let feed = Bundle.main.url(forResource: "mock_feed", withExtension: "mp4") {
                camera.setCameraFeed(fileURL: feed)
            }
            #else
            camera.setCameraFeed(cameraFacing: .back)
            #endif
            isEnabled = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
