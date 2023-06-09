import 'dart:convert' show AsciiDecoder;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:isolate_agents/isolate_agents.dart';
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:flutter/services.dart' show rootBundle;

/// Estado mantido pelo [Agente]. Ele apenas armazena a última mensagem decodificada e
/// diretório de documentos para que não precise ser consultado toda vez.
class _DecoderState {
  _DecoderState(this.documentsDir, this.lastDecodedMessage);

  /// O diretório do qual as mensagens são lidas. Armazenar isso no isolado é
   /// uma otimização que não pode ser obtida com a função `compute`.
   final Directory? documentsDir;

  /// Um valor `null` significa que chegamos ao fim das mensagens.
  final String? lastDecodedMessage;
}

/// Getter para o singleton [Agent] para decodificação.
final Future<Agent<_DecoderState>> _agent =
    Agent.create(() => _DecoderState(null, null));

/// Um método de codificação simples, rot13.
String _rot13Encode(String input) {
  List<int> output = [];

  for (int codeUnit in input.codeUnits) {
    if (codeUnit >= 32 && codeUnit <= 126) {
      int normalized = codeUnit - 32;
      int rot = (normalized + 13);
      if (rot > 94) {
        rot -= 94;
      }
      output.add(rot + 32);
    } else {
      output.add(codeUnit);
    }
  }

  return const AsciiDecoder().convert(output);
}

/// O decodificador para [_rot13Encode].
String _rot13Decode(String input) {
  List<int> output = [];

  for (int codeUnit in input.codeUnits) {
    if (codeUnit >= 32 && codeUnit <= 126) {
      int normalized = codeUnit - 32;
      int rot = normalized - 13;
      if (rot < 0) {
        rot += 94;
      }
      output.add(rot + 32);
    } else {
      output.add(codeUnit);
    }
  }

  return const AsciiDecoder().convert(output);
}

/// Enfileira um trabalho no [agente] para ler e decodificar uma das mensagens de
/// disco em [index].
void _loadMessage(Agent<_DecoderState> agent, int index) {
  agent.update((state) {
    File file = File('${state.documentsDir!.path}/$index.rot');
    if (file.existsSync()) {
      String encoded = file.readAsStringSync();
      return _DecoderState(state.documentsDir, _rot13Decode(encoded));
    } else {
      return _DecoderState(state.documentsDir, null);
    }
  });
}

/// Armazena no disco todas as mensagens de texto falsas criptografadas para que possamos carregar
/// então do Agente. Executamos isso no [Agente] para garantir que
/// isso é feito antes de começarmos a descriptografar as mensagens.
Future<void> _encodeMessages() async {
  Directory documentsPath =
      await path_provider.getApplicationDocumentsDirectory();
  Agent<_DecoderState> agent = await _agent;
  String text = await rootBundle.loadString('assets/romeojuliet.txt');
  agent.update((state) {
    List<String> lines = text.split('\n\n');
    int i = 0;
    for (String line in lines) {
      String encoded = _rot13Encode(line.trim());
      File('${documentsPath.path}/$i.rot').writeAsStringSync(encoded);
      i += 1;
    }
    // Leave in init state.
    return state;
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _encodeMessages();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(title: 'Romeo Juliet'),
    );
  }
}

/// Widget que representa o autor e uma mensagem.
class _Message extends StatelessWidget {
  const _Message(this.alignment, this.text);

  final TextAlign alignment;
  final String text;

  @override
  Widget build(BuildContext context) {
    const TextStyle textStyle = TextStyle(fontSize: 16);

    final EdgeInsets margin = alignment == TextAlign.left
        ? const EdgeInsets.fromLTRB(10, 10, 30, 30)
        : const EdgeInsets.fromLTRB(30, 10, 10, 30);
    final String name = alignment == TextAlign.left ? 'Romeo' : 'Juliet';
    final Color color =
        alignment == TextAlign.left ? Colors.lightBlue : Colors.grey;
    return Column(children: [
      SizedBox(
          width: double.infinity,
          height: 20,
          child: Text(
            name,
            style: textStyle,
            textAlign: alignment,
          )),
      SizedBox(
        width: double.infinity,
        child: Container(
          decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.all(Radius.circular(20))),
          margin: margin,
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: Text(
            text,
            textAlign: TextAlign.left,
            style: textStyle,
          ),
        ),
      )
    ]);
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() {
    return _MyHomePageState();
  }
}

/// Armazena [documentsDir] no [agent].
Future<void> _setDocumentsDir(
    Agent<_DecoderState> agent, Directory documentsDir) {
  return agent
      .update((state) => _DecoderState(documentsDir, state.lastDecodedMessage));
}

class _MyHomePageState extends State<MyHomePage> {
  int _messageCount = 0;
  
  // Armazenamos em cache as mensagens decodificadas no isolado raiz desde a visualização de rolagem
  // deslocamento irá pular para o topo se não souber sincronicamente o tamanho de um
  // ferramenta.
  final List<String> _decodedMessages = [];

  /// Isso define o diretório de documentos do [Agente] e dispara de forma assíncrona
  /// novas mensagens carregando jobs a cada segundo.
  Future<void> startLoadingMessages() async {
    final Agent<_DecoderState> agent = await _agent;

    // Armazena o diretório de documentos no agente para que não precise ser
    // consultado todas as vezes.
    Directory documentsDir =
        await path_provider.getApplicationDocumentsDirectory();
    await _setDocumentsDir(agent, documentsDir);

    bool keepLoading = true;
    while (keepLoading) {
      _loadMessage(agent, _messageCount);
      String? decodedMessage =
          await agent.read(query: (state) => state.lastDecodedMessage);
      if (decodedMessage != null) {
        _decodedMessages.add(decodedMessage);
        setState(() {
          _messageCount = _decodedMessages.length;
        });
      } else {
        keepLoading = false;
      }
      await Future.delayed(const Duration(milliseconds: 1000));
    }
  }

  @override
  void initState() {
    startLoadingMessages();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: ListView.builder(
          padding: const EdgeInsets.fromLTRB(0, 25, 0, 25),
          itemCount: _messageCount,
          itemBuilder: ((context, index) {
            if (index % 2 == 0) {
              return _Message(TextAlign.left, _decodedMessages[index]);
            } else {
              return _Message(TextAlign.right, _decodedMessages[index]);
            }
          })),
    );
  }
}
