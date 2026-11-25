import '../mesh/bridge.dart';

const requiredPermissions = ['bluetooth', 'wifi', 'notifications'];

const _web = {
  'bluetooth': 'granted',
  'wifi': 'granted',
  'notifications': 'granted',
  'microphone': 'granted',
};

bool allGranted(Map<String, String> p) =>
    requiredPermissions.every((k) => p[k] == 'granted');

Future<Map<String, String>> checkPermissions(Mesh mesh) async {
  if (!mesh.isNative) return Map.of(_web);
  return mesh.checkPermissions();
}

Future<Map<String, String>> requestPermissions(Mesh mesh) async {
  if (!mesh.isNative) return checkPermissions(mesh);
  return mesh.requestPermissions();
}
