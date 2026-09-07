import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinquest/features/rewards/digital/digital_reward_definition.dart';
import 'package:kinquest/features/rewards/digital/digital_reward_service.dart';

const _goldFrame = DigitalRewardDefinition(
  id: 'frame_gold',
  name: 'Golden Profile Frame',
  description: 'A golden frame.',
  cost: 250,
  category: DigitalRewardCategory.profileFrame,
  assetKey: 'gold',
  previewAsset: 'builtIn:frame_gold',
  isActive: true,
  isLimited: false,
  sortOrder: 10,
);

const _neonFrame = DigitalRewardDefinition(
  id: 'frame_neon',
  name: 'Neon Profile Frame',
  description: 'A neon frame.',
  cost: 320,
  category: DigitalRewardCategory.profileFrame,
  assetKey: 'neon',
  previewAsset: 'builtIn:frame_neon',
  isActive: true,
  isLimited: false,
  sortOrder: 20,
);

void main() {
  test(
    'purchase atomically spends exact Tokens and records ownership',
    () async {
      final firestore = await _seedFirestore(tokens: 1000);
      final service = _service(firestore);

      await service.purchase(_goldFrame.id);

      final user = await firestore.collection('users').doc('member-a').get();
      expect(user.data()!['tokens'], 750);
      expect(user.data()!['lastDigitalRewardPurchase'], _goldFrame.id);

      final owned = await firestore
          .collection('users')
          .doc('member-a')
          .collection('ownedRewards')
          .doc(_goldFrame.id)
          .get();
      expect(owned.data(), containsPair('rewardId', _goldFrame.id));
      expect(owned.data(), containsPair('cost', 250));
      expect(owned.data(), containsPair('category', 'profileFrame'));
      expect(owned.data(), containsPair('assetKey', 'gold'));
      expect(owned.data(), containsPair('equipped', false));

      final transactions = await firestore
          .collection('users')
          .doc('member-a')
          .collection('tokenTransactions')
          .get();
      expect(transactions.docs, hasLength(1));
      expect(transactions.docs.single.data()['amount'], -250);
      expect(transactions.docs.single.data()['relatedRewardId'], _goldFrame.id);
    },
  );

  test('Studio purchase equips in the same completed user action', () async {
    final firestore = await _seedFirestore(tokens: 1000);
    final service = _service(firestore);

    await service.purchaseAndEquip(_goldFrame.id);

    final owned = await firestore
        .collection('users')
        .doc('member-a')
        .collection('ownedRewards')
        .doc(_goldFrame.id)
        .get();
    final settings = await firestore
        .collection('users')
        .doc('member-a')
        .collection('settings')
        .doc('digitalRewards')
        .get();
    expect(owned.data()!['equipped'], true);
    expect(settings.data()!['profileFrame'], 'gold');
  });

  test('equip replaces the active item in the same category', () async {
    final firestore = await _seedFirestore(tokens: 1000);
    final service = _service(firestore);
    await service.purchaseAndEquip(_goldFrame.id);
    await service.purchase(_neonFrame.id);

    await service.equip(_neonFrame.id);

    final rewards = firestore
        .collection('users')
        .doc('member-a')
        .collection('ownedRewards');
    expect((await rewards.doc(_goldFrame.id).get()).data()!['equipped'], false);
    expect((await rewards.doc(_neonFrame.id).get()).data()!['equipped'], true);

    final settings = await firestore
        .collection('users')
        .doc('member-a')
        .collection('settings')
        .doc('digitalRewards')
        .get();
    expect(settings.data()!['profileFrame'], 'neon');
  });

  test('unequip clears both ownership marker and active setting', () async {
    final firestore = await _seedFirestore(tokens: 1000);
    final service = _service(firestore);
    await service.purchaseAndEquip(_goldFrame.id);

    await service.unequip(_goldFrame.id);

    final owned = await firestore
        .collection('users')
        .doc('member-a')
        .collection('ownedRewards')
        .doc(_goldFrame.id)
        .get();
    final settings = await firestore
        .collection('users')
        .doc('member-a')
        .collection('settings')
        .doc('digitalRewards')
        .get();
    expect(owned.data()!['equipped'], false);
    expect(settings.data()!['profileFrame'], 'default');
  });

  test('insufficient Tokens never creates ownership or a charge', () async {
    final firestore = await _seedFirestore(tokens: 100);
    final service = _service(firestore);

    await expectLater(
      service.purchase(_goldFrame.id),
      throwsA(
        isA<DigitalRewardException>().having(
          (error) => error.failure,
          'failure',
          DigitalRewardFailure.insufficientTokens,
        ),
      ),
    );

    final user = await firestore.collection('users').doc('member-a').get();
    final owned = await firestore
        .collection('users')
        .doc('member-a')
        .collection('ownedRewards')
        .get();
    final transactions = await firestore
        .collection('users')
        .doc('member-a')
        .collection('tokenTransactions')
        .get();
    expect(user.data()!['tokens'], 100);
    expect(owned.docs, isEmpty);
    expect(transactions.docs, isEmpty);
  });

  test('missing session and unknown rewards return stable failures', () async {
    final firestore = await _seedFirestore(tokens: 1000);
    final signedOutService = DigitalRewardService(
      firestore: firestore,
      userIdProvider: () => null,
      catalogLoader: () async => [_goldFrame, _neonFrame],
    );

    await expectLater(
      signedOutService.purchase(_goldFrame.id),
      throwsA(
        isA<DigitalRewardException>().having(
          (error) => error.failure,
          'failure',
          DigitalRewardFailure.signInRequired,
        ),
      ),
    );
    await expectLater(
      _service(firestore).equip('not-in-catalog'),
      throwsA(
        isA<DigitalRewardException>().having(
          (error) => error.failure,
          'failure',
          DigitalRewardFailure.unavailable,
        ),
      ),
    );
  });
}

DigitalRewardService _service(FakeFirebaseFirestore firestore) {
  return DigitalRewardService(
    firestore: firestore,
    userIdProvider: () => 'member-a',
    catalogLoader: () async => [_goldFrame, _neonFrame],
  );
}

Future<FakeFirebaseFirestore> _seedFirestore({required int tokens}) async {
  final firestore = FakeFirebaseFirestore();
  await firestore.collection('users').doc('member-a').set({
    'familyId': 'family-a',
    'tokens': tokens,
  });
  await firestore.collection('families').doc('family-a').set({
    'ownerId': 'member-a',
    'members': ['member-a'],
  });
  return firestore;
}
