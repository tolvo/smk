import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../main.dart';

class ChatScreen extends StatefulWidget {
  final String roomCode;
  final String nickname;

  const ChatScreen({super.key, required this.roomCode, required this.nickname});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _messages = <Map<String, dynamic>>[];
  final _scrollController = ScrollController();

  late WebSocketChannel _channel;
  bool _isConnected = false;

  // WebRTC Variables
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  bool _isP2PConnected = false;

  final Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
  };

  final Map<String, dynamic> _rtcConstraints = {
    'mandatory': {},
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
    ],
  };

  @override
  void initState() {
    super.initState();
    _connectWebSocket();
  }

  void _connectWebSocket() {
    final url =
        '${SmkApp.wsBaseUrl}/ws?room=${widget.roomCode}&nickname=${Uri.encodeComponent(widget.nickname)}';

    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));

      // Listen to the stream
      _channel.stream.listen(
        (data) async {
          if (!mounted) return;

          final message = jsonDecode(data);
          final type = message['type'] as String?;

          if (type == 'peer-joined') {
            _addSystemMessage('Par conectado. Iniciando canal P2P seguro...');
            _initiateWebRTC(true);
          } else if (type == 'offer') {
            _addSystemMessage('Recebendo solicitação de conexão P2P direta...');
            await _handleOffer(message['payload']);
          } else if (type == 'answer') {
            await _handleAnswer(message['payload']);
          } else if (type == 'candidate') {
            final candidateMap = message['payload'];
            if (_peerConnection != null && candidateMap != null) {
              try {
                final candidate = RTCIceCandidate(
                  candidateMap['candidate'],
                  candidateMap['sdpMid'],
                  candidateMap['sdpMLineIndex'],
                );
                await _peerConnection!.addCandidate(candidate);
              } catch (e) {
                print("Erro ao adicionar ICE Candidate: $e");
              }
            }
          } else if (type == 'leave') {
            _addSystemMessage(
              message['content'] ?? 'O outro participante saiu.',
            );
            _cleanupP2P();
          }
        },
        onDone: () {
          if (mounted) {
            // WebRTC connection can stay alive even if Signaling WS disconnects
            if (!_isP2PConnected) {
              setState(() {
                _isConnected = false;
              });
              _addSystemMessage('A conexão de sinalização foi encerrada.');
            }
          }
        },
        onError: (error) {
          if (mounted && !_isP2PConnected) {
            setState(() {
              _isConnected = false;
            });
            _addSystemMessage('Erro de conexão de sinalização: $error');
          }
        },
      );

      setState(() {
        _isConnected = true;
      });
    } catch (e) {
      _addSystemMessage('Não foi possível conectar ao servidor: $e');
    }
  }

  // Initiate WebRTC connection
  Future<void> _initiateWebRTC(bool isInitiator) async {
    await _cleanupP2P();

    try {
      _peerConnection = await createPeerConnection(_rtcConfig, _rtcConstraints);

      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (_isConnected) {
          _channel.sink.add(
            jsonEncode({
              'type': 'candidate',
              'payload': {
                'candidate': candidate.candidate,
                'sdpMid': candidate.sdpMid,
                'sdpMLineIndex': candidate.sdpMLineIndex,
              },
            }),
          );
        }
      };

      if (isInitiator) {
        // Create Data Channel
        _dataChannel = await _peerConnection!.createDataChannel(
          'chat',
          RTCDataChannelInit()..ordered = true,
        );
        _setupDataChannelHandlers(_dataChannel!);

        // Create Offer
        RTCSessionDescription offer = await _peerConnection!.createOffer({});
        await _peerConnection!.setLocalDescription(offer);

        _channel.sink.add(
          jsonEncode({
            'type': 'offer',
            'payload': {'sdp': offer.sdp, 'type': offer.type},
          }),
        );
      } else {
        // Wait for incoming Data Channel
        _peerConnection!.onDataChannel = (channel) {
          _dataChannel = channel;
          _setupDataChannelHandlers(_dataChannel!);
        };
      }
    } catch (e) {
      _addSystemMessage('Erro ao instanciar WebRTC: $e');
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> offerMap) async {
    await _initiateWebRTC(false);
    try {
      final offer = RTCSessionDescription(offerMap['sdp'], offerMap['type']);
      await _peerConnection!.setRemoteDescription(offer);

      RTCSessionDescription answer = await _peerConnection!.createAnswer({});
      await _peerConnection!.setLocalDescription(answer);

      _channel.sink.add(
        jsonEncode({
          'type': 'answer',
          'payload': {'sdp': answer.sdp, 'type': answer.type},
        }),
      );
    } catch (e) {
      _addSystemMessage('Erro ao aceitar proposta WebRTC.');
    }
  }

  Future<void> _handleAnswer(Map<String, dynamic> answerMap) async {
    if (_peerConnection == null) return;
    try {
      final answer = RTCSessionDescription(answerMap['sdp'], answerMap['type']);
      await _peerConnection!.setRemoteDescription(answer);
    } catch (e) {
      _addSystemMessage('Erro ao processar resposta WebRTC.');
    }
  }

  void _setupDataChannelHandlers(RTCDataChannel channel) {
    channel.onDataChannelState = (state) {
      if (!mounted) return;
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        setState(() {
          _isP2PConnected = true;
        });
        _addSystemMessage(
          'Conexão P2P (WebRTC) direta ativa! Todas as mensagens agora são transmitidas sem passar pelo servidor.',
        );
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        setState(() {
          _isP2PConnected = false;
        });
        _addSystemMessage('A conexão P2P direta foi encerrada.');
      }
    };

    channel.onMessage = (RTCDataChannelMessage message) {
      if (!mounted) return;
      final data = jsonDecode(message.text);
      setState(() {
        _messages.add({
          'type': 'chat',
          'sender': data['sender'],
          'content': data['content'],
          'timestamp': data['timestamp'],
        });
      });
      _scrollToBottom();
    };
  }

  Future<void> _cleanupP2P() async {
    await _dataChannel?.close();
    _dataChannel = null;
    await _peerConnection?.close();
    _peerConnection = null;
    if (mounted) {
      setState(() {
        _isP2PConnected = false;
      });
    }
  }

  void _addSystemMessage(String content) {
    setState(() {
      _messages.add({
        'type': 'system',
        'sender': 'System',
        'content': content,
        'timestamp': DateTime.now().toIso8601String(),
      });
    });
    _scrollToBottom();
  }

  // Send message over WebRTC RTCDataChannel
  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    if (_dataChannel == null || !_isP2PConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aguardando conexão direta WebRTC...')),
      );
      return;
    }

    final timestampStr = DateTime.now().toIso8601String();
    final payload = {
      'sender': widget.nickname,
      'content': text,
      'timestamp': timestampStr,
    };

    _dataChannel!.send(RTCDataChannelMessage(jsonEncode(payload)));

    setState(() {
      _messages.add({
        'type': 'chat',
        'sender': widget.nickname,
        'content': text,
        'timestamp': timestampStr,
      });
    });

    _messageController.clear();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _copyLink() {
    final shareUrl = '${SmkApp.apiBaseUrl}/join/${widget.roomCode}';
    Clipboard.setData(ClipboardData(text: shareUrl)).then((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Link do chat copiado para compartilhamento!'),
            backgroundColor: Theme.of(context).colorScheme.secondary,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _cleanupP2P();
    _channel.sink.close();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color statusColor = const Color(0xFFF43F5E);
    String statusText = 'Desconectado';

    if (_isP2PConnected) {
      statusColor = const Color(0xFF10B981);
      statusText = 'P2P Ativo';
    } else if (_isConnected) {
      statusColor = Colors.yellow;
      statusText = 'Sinalizando...';
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        backgroundColor: const Color(0xFF1E293B).withValues(alpha: 0.3),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Sair do Chat?'),
                content: const Text(
                  'Deseja realmente sair? Todas as mensagens desta sala serão perdidas definitivamente.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context); // Close dialog
                      Navigator.pop(context); // Leave chat screen
                    },
                    child: const Text(
                      'Sair',
                      style: TextStyle(color: Color(0xFFF43F5E)),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sala Privada',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  statusText,
                  style: TextStyle(fontSize: 11, color: statusColor),
                ),
              ],
            ),
          ],
        ),
        actions: [
          // Room Code Button
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: InkWell(
              onTap: _copyLink,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      widget.roomCode,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.copy_rounded,
                      size: 14,
                      color: Theme.of(context).primaryColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.2,
            colors: [Color(0xFF0F172A), Color(0xFF020617)],
          ),
        ),
        child: Column(
          children: [
            // Messages List
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  final type = msg['type'] as String?;
                  final sender = msg['sender'] as String? ?? '';
                  final content = msg['content'] as String? ?? '';
                  final timestamp = msg['timestamp'] as String? ?? '';

                  if (type == 'join' || type == 'leave' || type == 'system') {
                    return Align(
                      alignment: Alignment.center,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.01),
                          ),
                        ),
                        child: Text(
                          content,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }

                  final isSelf = sender == widget.nickname;

                  // Format Timestamp
                  String timeStr = '';
                  try {
                    final date = DateTime.parse(timestamp);
                    timeStr =
                        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
                  } catch (_) {}

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Column(
                      crossAxisAlignment: isSelf
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(
                            left: 6.0,
                            right: 6.0,
                            bottom: 2.0,
                          ),
                          child: Text(
                            isSelf ? 'Você' : sender,
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        Container(
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.75,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: isSelf
                                ? Theme.of(context).primaryColor
                                : Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(16),
                              topRight: const Radius.circular(16),
                              bottomLeft: isSelf
                                  ? const Radius.circular(16)
                                  : const Radius.circular(4),
                              bottomRight: isSelf
                                  ? const Radius.circular(4)
                                  : const Radius.circular(16),
                            ),
                            border: isSelf
                                ? null
                                : Border.all(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                          ),
                          child: Text(
                            content,
                            style: const TextStyle(
                              fontSize: 14.5,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(
                            left: 6.0,
                            right: 6.0,
                            top: 2.0,
                          ),
                          child: Text(
                            timeStr,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.35),
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            // Input Row
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withValues(alpha: 0.4),
                border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        decoration: InputDecoration(
                          hintText: 'Envie uma mensagem efêmera...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: const Color(
                            0xFF0F172A,
                          ).withValues(alpha: 0.6),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FloatingActionButton(
                      onPressed: _sendMessage,
                      backgroundColor: Theme.of(context).primaryColor,
                      mini: true,
                      child: const Icon(
                        Icons.send,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
