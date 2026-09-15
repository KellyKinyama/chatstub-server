import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

import '../auth/auth_service.dart';
import '../bubbles/bubble_repository.dart';
import '../files/http_upload.dart';
import '../messages/message_repository.dart';
import '../messages/reaction_repository.dart';
import '../push/push_token_repository.dart';
import '../sip/sip_gateway.dart';
import '../users/avatar_store.dart';
import '../users/presence_repository.dart';
import '../users/roster_repository.dart';
import '../users/user_repository.dart';
import '../users/vcard_repository.dart';
import 'router.dart';
import 'session.dart';

final _log = Logger('xmpp.ws');

Handler xmppWebSocketHandler({
  required String domain,
  required AuthService auth,
  required UserRepository users,
  required PresenceRepository presence,
  required MessageRepository messages,
  required ReactionRepository reactions,
  required BubbleRepository bubbles,
  required RosterRepository roster,
  required StanzaRouter router,
  required SmRegistry smRegistry,
  required PushTokenRepository pushTokens,
  required AvatarStore avatars,
  required VcardRepository vcards,
  required HttpUploadService upload,
  required String uploadBaseUrl,
  bool allowAnonymous = false,
  String? anonymousHost,
  SipGateway? sipGateway,
}) {
  return webSocketHandler((channel, protocol) async {
    _log.info('ws open protocol=$protocol');
    final session = XmppWsSession(
      channel: channel,
      domain: domain,
      auth: auth,
      users: users,
      presence: presence,
      messages: messages,
      reactions: reactions,
      bubbles: bubbles,
      roster: roster,
      router: router,
      smRegistry: smRegistry,
      pushTokens: pushTokens,
      avatars: avatars,
      vcards: vcards,
      upload: upload,
      uploadBaseUrl: uploadBaseUrl,
      allowAnonymous: allowAnonymous,
      anonymousHost: anonymousHost,
      sipGateway: sipGateway,
    );
    await session.run();
  }, protocols: const ['xmpp']);
}
