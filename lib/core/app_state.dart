import 'dart:async';

import 'package:flutter/foundation.dart';

import 'observable_collections.dart';

int _int(Object? v) => v is num ? v.toInt() : 0;
ObsMap? _map(Object? v) => v is ObsMap ? v : null;

extension type Profile(ObsMap m) implements ObsMap {
  String get name => m['name'] as String? ?? '';
  set name(String v) => m['name'] = v;
  String get ripploId => m['ripploId'] as String? ?? '';
  String get tag => m['tag'] as String? ?? '';
  String? get avatar => m['avatar'] as String?;
  set avatar(String? v) => m.put('avatar', v);
}

extension type Contact(ObsMap m) implements ObsMap {
  String get id => m['id'] as String;
  String get name => m['name'] as String? ?? '';
  set name(String v) => m['name'] = v;
  String? get ik => m['ik'] as String?;
  String? get card => m['card'] as String?;
  set card(String? v) => m.put('card', v);
  String get verification => m['verification'] as String? ?? 'none';
  set verification(String v) => m['verification'] = v;
  int get verifiedAt => _int(m['verifiedAt']);
  set verifiedAt(int v) => m['verifiedAt'] = v;
  String get verifyState => m['verifyState'] as String? ?? 'idle';
  set verifyState(String v) => m['verifyState'] = v;
  String? get addedVia => m['addedVia'] as String?;
  int get addedAt => _int(m['addedAt']);
  bool get conflict => m['conflict'] == true;
  set conflict(bool v) => m['conflict'] = v;
  String? get request => m['request'] as String?;
  set request(String? v) => m.put('request', v);
  String? get token => m['token'] as String?;
  set token(String? v) => m.put('token', v);
  bool get cardAck => m['cardAck'] == true;
  set cardAck(bool? v) => m.put('cardAck', v);
  int get cardSent => _int(m['cardSent']);
  set cardSent(int? v) => m.put('cardSent', v);
  Object? get avSent => m['avSent'];
  set avSent(Object? v) => m.put('avSent', v);
  Object? get nameSent => m['nameSent'];
  set nameSent(Object? v) => m.put('nameSent', v);
  Object? get vfSent => m['vfSent'];
  set vfSent(Object? v) => m.put('vfSent', v);
  bool get inviteFailed => m['inviteFailed'] == true;
  set inviteFailed(bool? v) => m.put('inviteFailed', v);
  String? get avatar => m['avatar'] as String?;
  set avatar(String? v) => m.put('avatar', v);
  ObsMap? get peerVerified => _map(m['peerVerified']);
  set peerVerified(Map<String, Object?>? v) => m.put('peerVerified', v);
}

extension type Chat(ObsMap m) implements ObsMap {
  String get id => m['id'] as String;
  String get type => m['type'] as String? ?? 'direct';
  String get name => m['name'] as String? ?? '';
  set name(String v) => m['name'] = v;
  String get lastText => m['lastText'] as String? ?? '';
  set lastText(String v) => m['lastText'] = v;
  String? get lastKind => m['lastKind'] as String?;
  set lastKind(String? v) => m['lastKind'] = v;
  int get lastTs => _int(m['lastTs']);
  set lastTs(int v) => m['lastTs'] = v;
  int get unread => _int(m['unread']);
  set unread(int v) => m['unread'] = v;
  List<Object?>? get members => m['members'] as List<Object?>?;
  set members(List<Object?>? v) => m.put('members', v);
}

extension type Att(ObsMap m) implements ObsMap {
  String get kind => m['kind'] as String? ?? '';
  String get mime => m['mime'] as String? ?? '';
  int get size => _int(m['size']);
  String? get attId => m['attId'] as String?;
  set attId(String? v) => m.put('attId', v);
  num? get duration => m['duration'] as num?;
  set duration(num? v) => m.put('duration', v);
  List<Object?>? get wave => m['wave'] as List<Object?>?;
  set wave(List<Object?>? v) => m.put('wave', v);
  Uint8List? get bytes => m['bytes'] as Uint8List?;
  set bytes(Uint8List? v) => m.put('bytes', v);
  String? get path => m['path'] as String?;
  set path(String? v) => m.put('path', v);
}

extension type Msg(ObsMap m) implements ObsMap {
  String get id => m['id'] as String;
  String get chatId => m['chatId'] as String;
  String get from => m['from'] as String;
  int get ts => _int(m['ts']);
  String get status => m['status'] as String? ?? '';
  set status(String v) => m['status'] = v;
  String? get text => m['text'] as String?;
  set text(String? v) => m.put('text', v);
  ObsMap? get re => _map(m['re']);
  set re(Map<String, Object?>? v) => m.put('re', v);
  Att? get att => _map(m['att']) == null ? null : Att(m['att'] as ObsMap);
  set att(Map<String, Object?>? v) => m.put('att', v);
  List<Object?>? get undelivered => m['undelivered'] as List<Object?>?;
  set undelivered(List<Object?>? v) => m.put('undelivered', v);
  int get delivered => _int(m['delivered']);
  set delivered(int v) => m['delivered'] = v;
  int get total => _int(m['total']);
  num? get progress => m['progress'] as num?;
  set progress(num? v) => m.put('progress', v);
  bool get errored => m['errored'] == true;
  set errored(bool? v) => m.put('errored', v);
  bool get unsent => m['unsent'] == true;
  set unsent(bool? v) => m.put('unsent', v);
}

extension type Neighbor(ObsMap m) implements ObsMap {
  String get node => m['node'] as String;
  String get medium => m['medium'] as String? ?? '';
  set medium(String v) => m['medium'] = v;
  num get kbps => m['kbps'] as num? ?? 0;
  set kbps(num v) => m['kbps'] = v;
  num? get rttMs => m['rttMs'] as num?;
  set rttMs(num? v) => m['rttMs'] = v;
}

extension type Person(ObsMap m) implements ObsMap {
  String get id => m['id'] as String;
  String get name => m['name'] as String? ?? '';
  String get card => m['card'] as String? ?? '';
  int get hops => _int(m['hops']);
  int get seenAt => _int(m['seenAt']);
  bool get isContact => m['isContact'] == true;
  set isContact(bool v) => m['isContact'] = v;
}

extension type CallInfo(ObsMap m) implements ObsMap {
  String get peer => m['peer'] as String;
  String get dir => m['dir'] as String;
  String get status => m['status'] as String;
  bool get muted => m['muted'] == true;
  int get startedAt => _int(m['startedAt']);
  String? get id => m['id'] as String?;
  String? get reason => m['reason'] as String?;
  ObsMap? get stats => _map(m['stats']);
  Object? get warn => m['warn'];
}

extension type DevLog(ObsMap m) implements ObsMap {
  String get id => m['id'] as String;
  String get from => m['from'] as String? ?? '';
  String get name => m['name'] as String? ?? '';
  int get ts => _int(m['ts']);
  String get text => m['text'] as String? ?? '';
}

extension type UpdateInfo(ObsMap m) implements ObsMap {
  String get current => m['current'] as String? ?? '';
  set current(String v) => m['current'] = v;
  int get checkedAt => _int(m['checkedAt']);
  set checkedAt(int v) => m['checkedAt'] = v;
  int get promptedAt => _int(m['promptedAt']);
  set promptedAt(int v) => m['promptedAt'] = v;
  bool get installing => m['installing'] == true;
  set installing(bool v) => m['installing'] = v;
  bool get checking => m['checking'] == true;
  set checking(bool v) => m['checking'] = v;
  String? get latest => m['latest'] as String?;
  set latest(String? v) => m['latest'] = v;
  bool get available => m['available'] == true;
  set available(bool v) => m['available'] = v;
  String? get url => m['url'] as String?;
  set url(String? v) => m['url'] = v;
  String? get apkUrl => m['apkUrl'] as String?;
  set apkUrl(String? v) => m['apkUrl'] = v;
  String? get sha256 => m['sha256'] as String?;
  set sha256(String? v) => m['sha256'] = v;
  num? get progress => m['progress'] as num?;
  set progress(num? v) => m['progress'] = v;
  String? get error => m['error'] as String?;
  set error(String? v) => m['error'] = v;
}

extension type Integrity(ObsMap m) implements ObsMap {
  String get status => m['status'] as String? ?? 'unknown';
  set status(String v) => m['status'] = v;
  int get checkedAt => _int(m['checkedAt']);
  set checkedAt(int v) => m['checkedAt'] = v;
}

extension type Settings(ObsMap m) implements ObsMap {
  bool get autoUpdate => m['autoUpdate'] == true;
  set autoUpdate(bool v) => m['autoUpdate'] = v;
  bool get backgroundRelay => m['backgroundRelay'] == true;
  set backgroundRelay(bool v) => m['backgroundRelay'] = v;
  bool get appLock => m['appLock'] == true;
  set appLock(bool? v) => m.put('appLock', v);
  bool get dev => m['dev'] == true;
  set dev(bool? v) => m.put('dev', v);
  bool get hidden => m['hidden'] == true;
  set hidden(bool? v) => m.put('hidden', v);
}

class RipploState extends ChangeNotifier {
  bool _queued = false;
  bool _disposed = false;

  void touch() {
    if (_queued || _disposed) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  ObsMap map([Map<Object?, Object?>? src]) => ObsMap(touch, src);
  ObsList<T> list<T>([Iterable<Object?>? src]) => ObsList<T>(touch, src);

  late final ObsMap data = map({
    'ready': false,
    'needsOnboarding': false,
    'insecureStorage': false,
    'devCrypto': false,
    'profile': null,
    'contacts': <String, Object?>{},
    'chats': list<Chat>(),
    'messages': <String, Object?>{},
    'typing': <String, Object?>{},
    'neighbors': list<Neighbor>(),
    'people': list<Person>(),
    'peopleRefreshedAt': 0,
    'peopleRefreshing': false,
    'peopleQuery': '',
    'call': null,
    'lockedCall': false,
    'update': {
      'current': '',
      'checkedAt': 0,
      'promptedAt': 0,
      'installing': false,
      'checking': false,
      'latest': null,
      'available': false,
      'url': null,
      'apkUrl': null,
      'sha256': null,
      'progress': null,
      'error': null,
    },
    'integrity': {'status': 'unknown', 'checkedAt': 0},
    'fromPlay': false,
    'settings': {'autoUpdate': true, 'backgroundRelay': true},
    'devLogs': list<DevLog>(),
  });

  bool get ready => data['ready'] == true;
  set ready(bool v) => data['ready'] = v;
  bool get needsOnboarding => data['needsOnboarding'] == true;
  set needsOnboarding(bool v) => data['needsOnboarding'] = v;
  bool get insecureStorage => data['insecureStorage'] == true;
  set insecureStorage(bool v) => data['insecureStorage'] = v;
  bool get devCrypto => data['devCrypto'] == true;
  set devCrypto(bool v) => data['devCrypto'] = v;
  bool get fromPlay => data['fromPlay'] == true;
  set fromPlay(bool v) => data['fromPlay'] = v;
  bool get lockedCall => data['lockedCall'] == true;
  set lockedCall(bool v) => data['lockedCall'] = v;
  bool get peopleRefreshing => data['peopleRefreshing'] == true;
  set peopleRefreshing(bool v) => data['peopleRefreshing'] = v;
  int get peopleRefreshedAt => _int(data['peopleRefreshedAt']);
  set peopleRefreshedAt(int v) => data['peopleRefreshedAt'] = v;
  String get peopleQuery => data['peopleQuery'] as String;
  set peopleQuery(String v) => data['peopleQuery'] = v;

  Profile? get profile =>
      _map(data['profile']) == null ? null : Profile(data['profile'] as ObsMap);
  set profile(Map<String, Object?>? v) => data['profile'] = v;
  CallInfo? get call =>
      _map(data['call']) == null ? null : CallInfo(data['call'] as ObsMap);
  set call(Map<String, Object?>? v) => data['call'] = v;

  ObsMap get contacts => data['contacts'] as ObsMap;
  set contacts(Map<String, Object?> v) => data['contacts'] = v;
  ObsMap get messages => data['messages'] as ObsMap;
  set messages(Map<String, Object?> v) => data['messages'] = v;
  ObsMap get typing => data['typing'] as ObsMap;
  set typing(Map<String, Object?> v) => data['typing'] = v;

  ObsList<Chat> get chats => data['chats'] as ObsList<Chat>;
  set chats(Iterable<Object?> v) =>
      data['chats'] = v is ObsList<Chat> ? v : list<Chat>(v);
  ObsList<Neighbor> get neighbors => data['neighbors'] as ObsList<Neighbor>;
  set neighbors(Iterable<Object?> v) =>
      data['neighbors'] = v is ObsList<Neighbor> ? v : list<Neighbor>(v);
  ObsList<Person> get people => data['people'] as ObsList<Person>;
  set people(Iterable<Object?> v) =>
      data['people'] = v is ObsList<Person> ? v : list<Person>(v);
  ObsList<DevLog> get devLogs => data['devLogs'] as ObsList<DevLog>;
  set devLogs(Iterable<Object?> v) =>
      data['devLogs'] = v is ObsList<DevLog> ? v : list<DevLog>(v);

  UpdateInfo get update => UpdateInfo(data['update'] as ObsMap);
  Integrity get integrity => Integrity(data['integrity'] as ObsMap);
  Settings get settings => Settings(data['settings'] as ObsMap);

  Contact? contact(String id) =>
      _map(contacts[id]) == null ? null : Contact(contacts[id] as ObsMap);
  ObsList<Msg>? msgs(String chatId) => messages[chatId] as ObsList<Msg>?;
}
