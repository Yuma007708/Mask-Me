# Run `xcodegen generate` first, then `pod install`, then open MaskMe.xcworkspace.
platform :ios, '16.0'

target 'MaskMe' do
  use_frameworks!
  # MediaPipe Face Landmarker (478-point face mesh). No official SwiftPM
  # distribution, so it is integrated into the app target via CocoaPods.
  pod 'MediaPipeTasksVision'

  target 'MaskMeTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  # MaskMe.debug.dylib と MaskMeTests.xctest の両方に
  # libMediaPipeTasksCommon_simulator_graph.a が force_load されると
  # FlowLimiterCalculator が二重登録されクラッシュする。
  # テストバンドル側の xcconfig から force_load フラグを除去する。
  Dir.glob("#{installer.sandbox.root}/Target Support Files/Pods-MaskMeTests/*.xcconfig").each do |path|
    content = File.read(path)
    cleaned = content.gsub(/-force_load\s+\S+/, '')
    File.write(path, cleaned) if cleaned != content
  end
end
