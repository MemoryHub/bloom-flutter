Pod::Spec.new do |s|
 s.name = 'bloom_provision'
 s.version = '0.1.1'
 s.summary = 'Bloom BLE provisioning using Espressif Security1.'
 s.homepage = 'https://bloom.jihu.top'
 s.license = { :file => '../LICENSE' }
 s.author = { 'Bloom' => 'dev@bloom.local' }
 s.source = { :path => '.' }
 s.source_files = 'Classes/**/*.swift', 'Vendor/ESPProvision/**/*.swift'
 s.dependency 'Flutter'
 s.dependency 'SwiftProtobuf', '1.22.0'
 s.platform = :ios, '14.0'
 s.swift_version = '5.0'
 s.frameworks = 'CoreBluetooth', 'NetworkExtension', 'AVFoundation'
end
