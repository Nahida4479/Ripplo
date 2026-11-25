import '../mesh/bridge.dart';
import 'messenger.dart';
import 'state.dart';

export 'messenger.dart' show maxText, maxFile;

const _devProfile = String.fromEnvironment('RIPPLO_PROFILE');

final state = RipploState();

final core = Core(
  mesh: mesh,
  state: state,
  dbName: !mesh.isNative && _devProfile.isNotEmpty
      ? 'ripplo-$_devProfile'
      : 'ripplo',
);

final init = core.init;
final createProfile = core.createProfile;
final setAvatar = core.setAvatar;
final setName = core.setName;
final myInviteLink = core.myInviteLink;
final addContactFromLink = core.addContactFromLink;
final invite = core.invite;
final acceptRequest = core.acceptRequest;
final declineRequest = core.declineRequest;
final verifyNearby = core.verifyNearby;
final verifyByQr = core.verifyByQr;
final markVerified = core.markVerified;
final safetyNumber = core.safetyNumber;
final sendTyping = core.sendTyping;
final sendText = core.sendText;
final sendAttachment = core.sendAttachment;
final retry = core.retry;
final loadMessages = core.loadMessages;
final markRead = core.markRead;
final createGroup = core.createGroup;
final unsendMessage = core.unsendMessage;
final refreshPeople = core.refreshPeople;
final searchPeople = core.searchPeople;
final startCall = core.startCall;
final acceptCall = core.acceptCall;
final hangUp = core.hangUp;
final setMuted = core.setMuted;
final deleteChat = core.deleteChat;
final deleteContact = core.deleteContact;
final saveSettings = core.saveSettings;
final restoreBackup = core.restoreBackup;
final sendDevLog = core.sendDevLog;
final deleteDevLog = core.deleteDevLog;
final nodeOf = core.nodeOf;
