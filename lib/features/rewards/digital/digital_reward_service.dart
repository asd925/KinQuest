import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'digital_reward_catalog.dart';
import 'digital_reward_definition.dart';
import 'equipped_digital_rewards.dart';

typedef DigitalRewardUserIdProvider = String? Function();
typedef DigitalRewardCatalogLoader =
    Future<List<DigitalRewardDefinition>> Function();

enum DigitalRewardFailure {
  signInRequired,
  unavailable,
  userNotFound,
  familyRequired,
  familyNotFound,
  notFamilyMember,
  alreadyOwned,
  insufficientTokens,
  notOwned,
  invalidReward,
  updateFailed,
}

class DigitalRewardException implements Exception {
  const DigitalRewardException(this.failure, {this.debugMessage});

  final DigitalRewardFailure failure;
  final String? debugMessage;

  @override
  String toString() => 'DigitalRewardException($failure)';
}

/// Owns the complete Digital Reward mutation flow.
///
/// The production Firebase project intentionally runs on the no-cost Spark
/// plan, so these mutations use atomic Firestore operations instead of relying
/// on an unavailable HTTP backend. Firestore rules independently validate the
/// canonical reward identifier, price, category, asset, token debit, and
/// equipped ownership.
class DigitalRewardService {
  DigitalRewardService({
    FirebaseFirestore? firestore,
    DigitalRewardUserIdProvider? userIdProvider,
    DigitalRewardCatalogLoader? catalogLoader,
  }) : _configuredFirestore = firestore,
       _userIdProvider =
           userIdProvider ?? (() => FirebaseAuth.instance.currentUser?.uid),
       _catalogLoader = catalogLoader ?? DigitalRewardCatalog.load;

  final FirebaseFirestore? _configuredFirestore;
  final DigitalRewardUserIdProvider _userIdProvider;
  final DigitalRewardCatalogLoader _catalogLoader;

  Future<List<DigitalRewardDefinition>>? _catalogFuture;

  FirebaseFirestore get _firestore =>
      _configuredFirestore ?? FirebaseFirestore.instance;

  Stream<EquippedDigitalRewards> watchEquipped(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('settings')
        .doc('digitalRewards')
        .snapshots()
        .map((snapshot) => EquippedDigitalRewards.fromMap(snapshot.data()));
  }

  /// Purchases an item without changing the currently equipped item.
  Future<void> purchase(String rewardId) async {
    final reward = await _rewardById(rewardId);
    await _purchase(reward, equipAfterPurchase: false);
  }

  /// Purchases and equips an item as one atomic user action.
  ///
  /// Sila Studio uses this path so a successful unlock can never leave the UI
  /// in the confusing "charged but not equipped" state.
  Future<void> purchaseAndEquip(String rewardId) async {
    final reward = await _rewardById(rewardId);
    await _purchase(reward, equipAfterPurchase: true);
  }

  Future<void> equip(String rewardId) async {
    final userId = _requireUserId();
    final reward = await _rewardById(rewardId);
    final userRef = _firestore.collection('users').doc(userId);
    final ownedRewardsRef = userRef.collection('ownedRewards');
    final selectedRef = ownedRewardsRef.doc(reward.id);
    final settingsRef = userRef.collection('settings').doc('digitalRewards');

    try {
      final sameCategory = await ownedRewardsRef
          .where('category', isEqualTo: reward.category.name)
          .get();

      await _firestore.runTransaction((transaction) async {
        final selectedSnapshot = await transaction.get(selectedRef);
        if (!selectedSnapshot.exists) {
          throw const DigitalRewardException(DigitalRewardFailure.notOwned);
        }
        _validateOwnedReward(selectedSnapshot.data(), reward);

        // Re-read every document inside the transaction before any writes so
        // retries preserve the one-equipped-item-per-category invariant.
        for (final document in sameCategory.docs) {
          if (document.id != reward.id) {
            await transaction.get(document.reference);
          }
        }

        for (final document in sameCategory.docs) {
          if (document.id != reward.id) {
            transaction.update(document.reference, {'equipped': false});
          }
        }
        transaction.update(selectedRef, {'equipped': true});
        transaction.set(settingsRef, {
          reward.category.name: reward.assetKey,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });
    } on DigitalRewardException {
      rethrow;
    } on FirebaseException catch (error) {
      throw DigitalRewardException(
        DigitalRewardFailure.updateFailed,
        debugMessage: '${error.code}: ${error.message ?? ''}',
      );
    }
  }

  Future<void> unequip(String rewardId) async {
    final userId = _requireUserId();
    final reward = await _rewardById(rewardId);
    final userRef = _firestore.collection('users').doc(userId);
    final ownedRewardRef = userRef.collection('ownedRewards').doc(reward.id);
    final settingsRef = userRef.collection('settings').doc('digitalRewards');

    try {
      await _firestore.runTransaction((transaction) async {
        final ownedSnapshot = await transaction.get(ownedRewardRef);
        if (!ownedSnapshot.exists) {
          throw const DigitalRewardException(DigitalRewardFailure.notOwned);
        }
        _validateOwnedReward(ownedSnapshot.data(), reward);

        transaction.update(ownedRewardRef, {'equipped': false});
        transaction.set(settingsRef, {
          reward.category.name: _unequippedAssetFor(reward.category),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });
    } on DigitalRewardException {
      rethrow;
    } on FirebaseException catch (error) {
      throw DigitalRewardException(
        DigitalRewardFailure.updateFailed,
        debugMessage: '${error.code}: ${error.message ?? ''}',
      );
    }
  }

  Future<void> _purchase(
    DigitalRewardDefinition reward, {
    required bool equipAfterPurchase,
  }) async {
    final userId = _requireUserId();
    final userRef = _firestore.collection('users').doc(userId);
    final ownedRewardsRef = userRef.collection('ownedRewards');
    final ownedRewardRef = ownedRewardsRef.doc(reward.id);
    final settingsRef = userRef.collection('settings').doc('digitalRewards');
    final tokenTransactionRef = userRef.collection('tokenTransactions').doc();

    try {
      final sameCategory = equipAfterPurchase
          ? await ownedRewardsRef
                .where('category', isEqualTo: reward.category.name)
                .get()
          : null;

      await _firestore.runTransaction((transaction) async {
        final userSnapshot = await transaction.get(userRef);
        final userData = userSnapshot.data();
        if (!userSnapshot.exists || userData == null) {
          throw const DigitalRewardException(DigitalRewardFailure.userNotFound);
        }

        final familyId = userData['familyId']?.toString().trim() ?? '';
        if (familyId.isEmpty) {
          throw const DigitalRewardException(
            DigitalRewardFailure.familyRequired,
          );
        }

        final familySnapshot = await transaction.get(
          _firestore.collection('families').doc(familyId),
        );
        if (!familySnapshot.exists) {
          throw const DigitalRewardException(
            DigitalRewardFailure.familyNotFound,
          );
        }

        final members =
            (familySnapshot.data()?['members'] as List<dynamic>?)
                ?.map((member) => member.toString())
                .toSet() ??
            const <String>{};
        if (!members.contains(userId)) {
          throw const DigitalRewardException(
            DigitalRewardFailure.notFamilyMember,
          );
        }

        final ownedSnapshot = await transaction.get(ownedRewardRef);
        if (ownedSnapshot.exists) {
          throw const DigitalRewardException(DigitalRewardFailure.alreadyOwned);
        }

        if (sameCategory != null) {
          for (final document in sameCategory.docs) {
            await transaction.get(document.reference);
          }
        }

        final tokens = (userData['tokens'] as num?)?.toInt() ?? 0;
        if (tokens < reward.cost) {
          throw const DigitalRewardException(
            DigitalRewardFailure.insufficientTokens,
          );
        }

        transaction.update(userRef, {
          'tokens': tokens - reward.cost,
          'lastDigitalRewardPurchase': reward.id,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        if (sameCategory != null) {
          for (final document in sameCategory.docs) {
            transaction.update(document.reference, {'equipped': false});
          }
        }
        transaction.set(ownedRewardRef, {
          'rewardId': reward.id,
          'name': reward.name,
          'description': reward.description,
          'cost': reward.cost,
          'category': reward.category.name,
          'assetKey': reward.assetKey,
          'previewAsset': reward.previewAsset,
          'purchasedAt': FieldValue.serverTimestamp(),
          'equipped': equipAfterPurchase,
        });
        if (equipAfterPurchase) {
          transaction.set(settingsRef, {
            reward.category.name: reward.assetKey,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
        transaction.set(tokenTransactionRef, {
          'userId': userId,
          'familyId': familyId,
          'amount': -reward.cost,
          'type': 'spent',
          'reason': 'Digital reward: ${reward.name}',
          'relatedRewardId': reward.id,
          'relatedRequestId': null,
          'relatedCompetitionId': null,
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
    } on DigitalRewardException {
      rethrow;
    } on FirebaseException catch (error) {
      throw DigitalRewardException(
        DigitalRewardFailure.updateFailed,
        debugMessage: '${error.code}: ${error.message ?? ''}',
      );
    }
  }

  String _requireUserId() {
    final userId = _userIdProvider()?.trim() ?? '';
    if (userId.isEmpty) {
      throw const DigitalRewardException(DigitalRewardFailure.signInRequired);
    }
    return userId;
  }

  Future<DigitalRewardDefinition> _rewardById(String rewardId) async {
    final normalizedId = rewardId.trim();
    if (normalizedId.isEmpty) {
      throw const DigitalRewardException(DigitalRewardFailure.invalidReward);
    }

    final catalog = await (_catalogFuture ??= _catalogLoader());
    for (final reward in catalog) {
      if (reward.id == normalizedId) return reward;
    }

    throw const DigitalRewardException(DigitalRewardFailure.unavailable);
  }

  void _validateOwnedReward(
    Map<String, dynamic>? data,
    DigitalRewardDefinition reward,
  ) {
    if (data?['rewardId'] != reward.id ||
        data?['category'] != reward.category.name ||
        data?['assetKey'] != reward.assetKey) {
      throw const DigitalRewardException(DigitalRewardFailure.invalidReward);
    }
  }

  String _unequippedAssetFor(DigitalRewardCategory category) {
    return switch (category) {
      DigitalRewardCategory.profileBadge ||
      DigitalRewardCategory.mascotAccessory ||
      DigitalRewardCategory.mascotOutfit ||
      DigitalRewardCategory.mascotAura => 'none',
      DigitalRewardCategory.profileFrame ||
      DigitalRewardCategory.profileTheme ||
      DigitalRewardCategory.celebrationEffect ||
      DigitalRewardCategory.nameplate => 'default',
    };
  }
}
