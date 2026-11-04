import 'package:pos_shared/pos_shared.dart';
import 'package:test/test.dart';

void main() {
  group('normalizePairingCode', () {
    test('accepts what a manager reads off the screen', () {
      expect(normalizePairingCode('abcd-efgh'), 'ABCDEFGH');
      expect(normalizePairingCode(' 2345 6789 '), '23456789');
    });

    test('rejects ambiguous characters and wrong lengths', () {
      expect(normalizePairingCode('ABCD-EFG0'), isNull);
      expect(normalizePairingCode('ABCD-EFGI'), isNull);
      expect(normalizePairingCode('ABCD-EFGL'), isNull);
      expect(normalizePairingCode('ABCD-EFG'), isNull);
    });
  });

  test('Device.fromMap reads a paired device', () {
    final device = Device.fromMap('dev_1', {
      'orgId': 'org-a',
      'locationId': 'cambridge',
      'type': 'kds',
      'name': 'Kitchen',
      'status': 'revoked',
    });
    expect(device.type, DeviceType.kds);
    expect(device.status, DeviceStatus.revoked);
  });
}
