import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:ripplo/core/app_state.dart';
import 'package:ripplo/translations.dart';
import 'package:ripplo/ui/ui_request_state.dart';

typedef Json = Map<String, Object?>;

const String kBobId = '4047KDQS657BTPBH';
const String kCarolId = '9TE42XV903MGXRME';
const String kDaveId = '0KSTRJA1GA47W8QQ';
const String kGroupId = 'WwGYTnHWqLf3';
const String kImageAttId = '53e020ca9d662858c73a6d8d86340d26';
const String kAccentHex = '#1e3a8a';
const String kGradientHex = '#5b2ea6';

const List<String> kSceneNames = [
  'onboarding-empty',
  'onboarding-filled',
  'gate-needed',
  'gate-partial',
  'gate-optional',
  'chats-empty',
  'chats-list',
  'chats-list-accent',
  'chats-requests',
  'chat-empty',
  'chat-staged',
  'chat-staged-two',
  'chat-messages',
  'chat-messages-accent',
  'chat-typing',
  'chat-composer',
  'chat-reply',
  'chat-unverified',
  'chat-group',
  'addcontact-code',
  'addcontact-scan',
  'addcontact-paste-empty',
  'addcontact-paste-filled',
  'addcontact-verify',
  'newchat-empty',
  'newchat-contacts',
  'newchat-group',
  'people-empty',
  'people-nearby',
  'people-request',
  'people-mesh',
  'contact-verified',
  'contact-unverified',
  'confirm-sure',
  'confirm-delete',
  'confirm-invite',
  'settings-top',
  'settings-top-accent',
  'settings-appearance',
  'settings-network',
  'settings-security',
  'settings-updates',
  'settings-about',
  'settings-contributors',
  'settings-dev',
  'share-text',
  'lock-locked',
  'call-incoming',
  'call-active',
  'call-outgoing',
  'toast-camera',
];

class Scene {
  Scene({
    required this.name,
    required this.state,
    required this.nowMs,
    required this.route,
    this.id,
    this.accent = '#4f9cf9',
    this.gradient = '',
    this.extras = const {},
    this.blobs = const {},
    void Function(UiState u)? ui,
  }) : _ui = ui;

  final String name;
  final RipploState state;
  final int nowMs;
  final String route;
  final String? id;
  final String accent;
  final String gradient;
  final Json extras;
  final Map<String, Uint8List> blobs;
  final void Function(UiState u)? _ui;

  String get screen => name.split('-').first;
  String get variant => name.substring(screen.length + 1);

  void applyUi(UiState u) {
    u.reset();
    _ui?.call(u);
  }
}

int at(int day, int h, int m, [int s = 0]) =>
    DateTime.utc(2026, 1, day, h - 1, m, s).millisecondsSinceEpoch;

Uint8List fixturePng(int w, int h) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, (x * 255 / w).round(), (y * 255 / h).round(), 140);
    }
  }
  return img.encodePng(im);
}

String? _raw;
Json _file() {
  _raw ??= File('test/support/fixture_state.json').readAsStringSync();
  return jsonDecode(_raw!) as Json;
}

String get fixtureMyLink => _file()['link'] as String;
String get fixtureBobLink => _file()['bobLink'] as String;
Map<String, String> get fixtureSafety =>
    (_file()['safety'] as Map).cast<String, String>();

Json _base() => (_file()['state'] as Json);

List<Json> _list(Object? v) => (v as List).cast<Json>();

Json _contact(Json s, String id) => (s['contacts'] as Json)[id] as Json;

Json _chat(Json s, String id) =>
    _list(s['chats']).firstWhere((c) => c['id'] == id);

List<Json> _msgs(Json s, String id) => _list((s['messages'] as Json)[id]);

const String _seeYouSoon = 'See you soon';

Json _stage(String stage) {
  final s = _base();
  final chats = _list(s['chats']);
  final messages = s['messages'] as Json;
  final bobAll = _msgs(s, kBobId);
  final bobEarly = bobAll.where((m) => m['text'] != _seeYouSoon).toList();
  final bobFive = bobEarly.take(5).toList();
  final bobChat = Map<String, Object?>.from(_chat(s, kBobId));
  final carolChat = Map<String, Object?>.from(_chat(s, kCarolId));
  final groupChat = Map<String, Object?>.from(_chat(s, kGroupId));
  final bob = _contact(s, kBobId);
  final carol = Map<String, Object?>.from(_contact(s, kCarolId))
    ..['verifyState'] = 'failed';
  final dave = _contact(s, kDaveId);
  final neighbors = _list(s['neighbors']);
  final bobNeighbor = neighbors
      .where((n) => (n['card'] as Json)['id'] == kBobId)
      .toList();
  final bobMsgsLate = bobAll;

  void put({
    required Map<String, Json> c,
    required List<Json> ch,
    required Json m,
    required List<Json> nb,
  }) {
    s['contacts'] = c;
    s['chats'] = ch;
    s['messages'] = m;
    s['neighbors'] = nb;
    s['people'] = <Json>[];
    s['peopleRefreshedAt'] = 0;
    s['typing'] = {kBobId: <Object?>[]};
    (s['settings'] as Json)['dev'] = false;
  }

  Json imageChat() => {
    ...bobChat,
    'lastText': '',
    'lastKind': 'image',
    'lastTs': 1768469166045,
    'unread': 0,
  };

  Json bobFresh() => {
    ...bobChat,
    'lastText': '',
    'lastKind': null,
    'lastTs': bob['addedAt'],
    'unread': 0,
  };

  switch (stage) {
    case 'onboarding':
      put(c: {}, ch: [], m: {}, nb: []);
      s['needsOnboarding'] = true;
      s['profile'] = null;
    case 'empty':
      put(c: {}, ch: [], m: {}, nb: []);
    case 'emptyBobNear':
      put(c: {}, ch: [], m: {}, nb: bobNeighbor);
    case 'bob':
      put(c: {kBobId: bob}, ch: [bobFresh()], m: {}, nb: bobNeighbor);
    case 'bobEarly':
      put(
        c: {kBobId: bob},
        ch: [
          {
            ...bobChat,
            'lastText': 'Coffee at 10:30 then',
            'lastTs': 1768469045079,
            'unread': 0,
          },
        ],
        m: {kBobId: bobFive},
        nb: bobNeighbor,
      );
    case 'bobChat':
      put(
        c: {kBobId: bob},
        ch: [imageChat()],
        m: {kBobId: bobEarly},
        nb: bobNeighbor,
      );
    case 'carol':
    case 'carolMsgs':
    case 'carolSheet':
      put(
        c: {kBobId: bob, kCarolId: carol},
        ch: [carolChat, imageChat()]
          ..sort((a, b) => (b['lastTs'] as int).compareTo(a['lastTs'] as int)),
        m: {
          kBobId: bobEarly,
          if (stage == 'carolMsgs') kCarolId: _msgs(s, kCarolId),
        },
        nb: bobNeighbor,
      );
    case 'group':
      put(
        c: {kBobId: bob, kCarolId: carol},
        ch: [groupChat, imageChat(), carolChat],
        m: {
          kBobId: bobEarly,
          kCarolId: _msgs(s, kCarolId),
          kGroupId: _msgs(s, kGroupId),
        },
        nb: bobNeighbor,
      );
    case 'list':
      put(
        c: {kBobId: bob, kCarolId: carol},
        ch: chats,
        m: {...messages, kBobId: bobMsgsLate},
        nb: bobNeighbor,
      );
    case 'nearby':
      put(
        c: {kBobId: bob, kCarolId: carol},
        ch: chats,
        m: {...messages, kBobId: bobMsgsLate},
        nb: neighbors,
      );
    case 'request':
      put(
        c: {kBobId: bob, kCarolId: carol, kDaveId: dave},
        ch: chats,
        m: {...messages, kBobId: bobMsgsLate},
        nb: neighbors,
      );
    case 'mesh':
      s['contacts'] = {kBobId: bob, kCarolId: carol, kDaveId: dave};
      s['typing'] = {kBobId: <Object?>[]};
      (s['settings'] as Json)['dev'] = false;
    case 'dev':
      s['contacts'] = {kBobId: bob, kCarolId: carol, kDaveId: dave};
    default:
      throw ArgumentError(stage);
  }
  if (stage != 'onboarding') {
    s['contacts'] = Map.of(s['contacts'] as Json);
  }
  for (final ml in (s['messages'] as Json).values) {
    (ml as List).sort(
      (a, b) => ((a as Json)['ts'] as int).compareTo((b as Json)['ts'] as int),
    );
  }
  return s;
}

RipploState _load(Json s) {
  final st = RipploState();
  for (final e in s.entries) {
    final v = e.value;
    switch (e.key) {
      case 'chats':
        st.chats = (v as List).cast<Object?>();
      case 'neighbors':
        st.neighbors = (v as List).cast<Object?>();
      case 'people':
        st.people = (v as List).cast<Object?>();
      case 'devLogs':
        st.devLogs = (v as List).cast<Object?>();
      case 'messages':
        st.data['messages'] = st.map({
          for (final m in (v as Json).entries)
            m.key: st.list<Msg>(m.value as List),
        });
      default:
        st.data[e.key] = v;
    }
  }
  return st;
}

Scene scene(String name) {
  late String stage;
  late int now;
  var route = 'chats';
  String? id;
  var accent = '#4f9cf9';
  var gradient = '';
  final extras = <String, Object?>{};
  void Function(UiState u)? uiFn;
  final blobs = <String, Uint8List>{kImageAttId: fixturePng(240, 160)};

  void accented() {
    accent = kAccentHex;
    gradient = kGradientHex;
  }

  switch (name) {
    case 'onboarding-empty':
    case 'onboarding-filled':
      stage = 'onboarding';
      now = at(14, 20, 50, 10);
      route = 'onboarding';
      extras['name'] = name == 'onboarding-filled' ? 'Alice' : '';
    case 'gate-needed':
    case 'gate-partial':
    case 'gate-optional':
      stage = 'onboarding';
      now = at(14, 20, 50, 10);
      route = 'gate';
      extras['perms'] = switch (name) {
        'gate-needed' => {
          'bluetooth': 'prompt',
          'wifi': 'prompt',
          'notifications': 'prompt',
          'microphone': 'prompt',
          'fullscreen': 'prompt',
          'battery': 'prompt',
        },
        'gate-partial' => {
          'bluetooth': 'granted',
          'wifi': 'denied',
          'notifications': 'prompt',
          'microphone': 'granted',
          'fullscreen': 'prompt',
          'battery': 'prompt',
        },
        _ => {
          'bluetooth': 'granted',
          'wifi': 'granted',
          'notifications': 'granted',
          'microphone': 'prompt',
          'fullscreen': 'prompt',
          'battery': 'prompt',
        },
      };
    case 'chats-empty':
      stage = 'empty';
      now = at(14, 20, 50, 20);
    case 'addcontact-code':
    case 'addcontact-scan':
    case 'addcontact-paste-empty':
    case 'toast-camera':
      stage = 'empty';
      now = at(14, 20, 50, 20);
      final tab = name == 'addcontact-code'
          ? 'code'
          : name == 'addcontact-paste-empty'
          ? 'paste'
          : 'scan';
      extras['tab'] = tab;
      extras['link'] = fixtureMyLink;
      uiFn = (u) {
        u.add = const AddRequest();
        if (name == 'toast-camera') u.toastText = t('cameraDenied');
      };
    case 'addcontact-paste-filled':
      stage = 'emptyBobNear';
      now = at(14, 20, 50, 20);
      extras['tab'] = 'paste';
      extras['pasteText'] = fixtureBobLink;
      uiFn = (u) => u.add = const AddRequest();
    case 'newchat-empty':
      stage = 'empty';
      now = at(14, 20, 50, 20);
      uiFn = (u) => u.newChat = 'chat';
    case 'people-empty':
      stage = 'empty';
      now = at(14, 20, 50, 25);
      route = 'people';
    case 'contact-verified':
      stage = 'bob';
      now = at(14, 20, 50, 40);
      route = 'contact';
      id = kBobId;
    case 'chat-staged':
      stage = 'bobEarly';
      now = at(15, 10, 26, 10);
      route = 'chat';
      id = kBobId;
      extras['staged'] = [
        [240, 160],
      ];
    case 'chat-messages':
    case 'chat-messages-accent':
    case 'chat-typing':
    case 'chat-composer':
    case 'chat-reply':
    case 'chat-staged-two':
      stage = 'bobChat';
      now = at(15, 10, 27, 30);
      route = 'chat';
      id = kBobId;
      if (name == 'chat-messages-accent') accented();
      if (name == 'chat-composer') {
        extras['text'] = 'See you at the square in ten minutes';
      }
      if (name == 'chat-reply') extras['replyText'] = 'On my way.';
      if (name == 'chat-staged-two') {
        extras['text'] = 'Two photos';
        extras['staged'] = [
          [240, 160],
          [120, 200],
        ];
      }
    case 'contact-unverified':
    case 'confirm-sure':
    case 'confirm-delete':
      stage = 'carol';
      now = at(15, 10, 28, 10);
      route = 'contact';
      id = kCarolId;
      if (name == 'confirm-sure') {
        uiFn = (u) => u.confirm = ConfirmRequest(
          title: t('imSure'),
          text: t('imSureConfirm'),
          ok: t('confirm'),
          onOk: () {},
        );
      } else if (name == 'confirm-delete') {
        uiFn = (u) => u.confirm = ConfirmRequest(
          title: t('deleteContact'),
          text: t('deleteContactConfirm'),
          ok: t('delete'),
          danger: true,
          onOk: () {},
        );
      }
    case 'addcontact-verify':
      stage = 'carol';
      now = at(15, 10, 28, 20);
      route = 'contact';
      id = kCarolId;
      extras['link'] = fixtureMyLink;
      uiFn = (u) => u.add = const AddRequest(mode: 'verify', id: kCarolId);
    case 'chat-empty':
      stage = 'carol';
      now = at(15, 10, 28, 30);
      route = 'chat';
      id = kCarolId;
    case 'chat-unverified':
      stage = 'carolMsgs';
      now = at(15, 10, 29, 55);
      route = 'chat';
      id = kCarolId;
    case 'newchat-contacts':
    case 'newchat-group':
      stage = 'carol';
      now = at(15, 10, 29, 45);
      uiFn = (u) => u.newChat = name == 'newchat-group' ? 'group' : 'chat';
      if (name == 'newchat-group') {
        extras['groupName'] = 'Trip crew';
        extras['picked'] = [kBobId, kCarolId];
      }
    case 'chat-group':
      stage = 'group';
      now = at(15, 10, 29, 58);
      route = 'chat';
      id = kGroupId;
    case 'chats-list':
    case 'chats-list-accent':
      stage = 'list';
      now = at(15, 10, 30, 10);
      if (name == 'chats-list-accent') accented();
    case 'people-nearby':
    case 'confirm-invite':
      stage = 'nearby';
      now = at(15, 10, 30, 15);
      route = 'people';
      if (name == 'confirm-invite') {
        uiFn = (u) => u.confirm = ConfirmRequest(
          title: t('inviteTitle', {'name': 'Dave'}),
          text: t('inviteText'),
          ok: t('invite'),
          onOk: () {},
        );
      }
    case 'people-request':
      stage = 'request';
      now = at(15, 10, 30, 25);
      route = 'people';
    case 'chats-requests':
      stage = 'request';
      now = at(15, 10, 30, 30);
    case 'people-mesh':
      stage = 'mesh';
      now = at(15, 10, 30, 40);
      route = 'people';
    case 'settings-top':
    case 'settings-top-accent':
    case 'settings-appearance':
    case 'settings-network':
    case 'settings-security':
    case 'settings-updates':
    case 'settings-about':
    case 'settings-contributors':
      stage = 'mesh';
      now = at(15, 10, 31);
      route = 'settings';
      if (name == 'settings-top-accent') accented();
      extras['section'] = const {
        'settings-appearance': 'Appearance',
        'settings-network': 'Network',
        'settings-security': 'Security',
        'settings-updates': 'Updates',
        'settings-about': 'About',
        'settings-contributors': 'Contributors',
      }[name];
    case 'settings-dev':
      stage = 'dev';
      now = at(15, 10, 31, 20);
      route = 'settings';
      extras['section'] = 'Developer';
    case 'share-text':
      stage = 'dev';
      now = at(15, 10, 31, 30);
      uiFn = (u) => u.share = const ShareRequest(
        kind: 'text',
        text: 'Join me on Ripplo, a messenger that works without internet.',
      );
    case 'lock-locked':
      stage = 'dev';
      now = at(15, 10, 31, 40);
      extras['locked'] = true;
    case 'call-incoming':
    case 'call-outgoing':
      stage = 'dev';
      now = at(15, 10, 31, 50);
    case 'call-active':
      stage = 'dev';
      now = at(15, 10, 32);
    default:
      throw ArgumentError('unknown scene $name');
  }

  final s = _stage(stage);
  if (stage == 'dev') {
    s['people'] = _list(_base()['people']);
    s['peopleRefreshedAt'] = _base()['peopleRefreshedAt'];
    (s['settings'] as Json)['dev'] = name == 'settings-dev';
  }
  if (stage == 'mesh') {
    s['people'] = _list(_base()['people']);
    s['peopleRefreshedAt'] = _base()['peopleRefreshedAt'];
  }
  if (route == 'settings' || stage == 'dev') {
    final u = s['update'] as Json;
    u['latest'] = u['current'];
    u['error'] = null;
    u['available'] = false;
  }
  if (name.startsWith('call-')) {
    s['call'] = switch (name) {
      'call-incoming' => {'peer': kBobId, 'status': 'ringing', 'dir': 'in'},
      'call-outgoing' => {'peer': kBobId, 'status': 'ringing', 'dir': 'out'},
      _ => {
        'peer': kBobId,
        'status': 'active',
        'dir': 'out',
        'muted': false,
        'startedAt': now - 83000,
        'warn': 'out',
        'stats': {
          'sent': 4120,
          'recv': 4098,
          'played': 4090,
          'errors': 0,
          'track': 'live',
          'audio': 'running',
          'frames': 4098,
        },
      },
    };
  }
  return Scene(
    name: name,
    state: _load(s),
    nowMs: now,
    route: route,
    id: id,
    accent: accent,
    gradient: gradient,
    extras: extras,
    blobs: blobs,
    ui: uiFn,
  );
}
