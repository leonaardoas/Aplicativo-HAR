import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fl_chart/fl_chart.dart'; // Importação para fl_chart

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueAccent,
          brightness: Brightness.dark,
          primary: const Color(0xFF90CAF9),
          onPrimary: Colors.black,
          secondary: const Color(0xFF42A5F5),
          onSecondary: Colors.black,
          surface: const Color(0xFF1E1E1E),
        ),
        scaffoldBackgroundColor: const Color(0xFF121212),
        cardColor: const Color(0xFF1E1E1E),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          elevation: 4.0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF42A5F5),
            foregroundColor: Colors.black,
          ),
        ),
      ),
      home: const HARApp(),
    );
  }
}

class HARApp extends StatefulWidget {
  const HARApp({super.key});

  @override
  State<HARApp> createState() => _HARAppState();
}

class _HARAppState extends State<HARApp> {
  Interpreter? interpreter;
  final FlutterTts tts = FlutterTts();
  List<List<double>> window = List.generate(200, (_) => [0.0, 0.0, 0.0]);
  List<String> history = [];
  Timer? predictionTimer;
  final labelMap = ['Devagar', 'Moderada', 'Vigorosa'];
  int lastPrediction = -1;

  final List<FlSpot> _xDataPoints = [];
  final List<FlSpot> _yDataPoints = [];
  final List<FlSpot> _zDataPoints = [];
  int _dataPointCounter = 0;
  final int _maxDataPoints = 100;

  StreamSubscription? _accelerometerSubscription;
  bool _isCollecting = false; // Estado para controlar a coleta de dados

  // Definindo as cores do gráfico para fácil referência
  static const Color xColor = Colors.greenAccent;
  static const Color yColor = Colors.yellowAccent;
  static const Color zColor = Colors.blueAccent;


  @override
  void initState() {
    super.initState();
    loadModel();
    _initTTS();
    // Não inicia a coleta automaticamente
  }

  @override
  void dispose() {
    predictionTimer?.cancel();
    _accelerometerSubscription?.cancel();
    interpreter?.close();
    tts.stop(); // Para o TTS se estiver falando
    super.dispose();
  }

  Future<void> loadModel() async {
    try {
      interpreter = await Interpreter.fromAsset('assets/model.tflite');
      debugPrint('Modelo carregado com sucesso!');
      // Verifica se o modelo tem os tensores de entrada e saída esperados
      // Isso é opcional, mas bom para depuração
      if (interpreter != null) {
        debugPrint('Input tensors: ${interpreter!.getInputTensors()}');
        debugPrint('Output tensors: ${interpreter!.getOutputTensors()}');
      }
    } catch (e) {
      debugPrint('Falha ao carregar modelo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao carregar modelo: $e')),
        );
      }
    }
  }

  Future<void> _initTTS() async {
    await tts.setLanguage("pt-BR");
    await tts.setSpeechRate(0.5);
  }

  void _startSensors() {
    if (_accelerometerSubscription != null) {
      _accelerometerSubscription!.cancel(); // Cancela subscrição anterior se houver
    }
    _accelerometerSubscription = accelerometerEventStream(
      samplingPeriod: SensorInterval.uiInterval // Frequência de atualização para UI
    ).listen((AccelerometerEvent event) {
      if (!_isCollecting) return; // Só processa se estiver coletando

      if (window.length == 200) {
        window.removeAt(0);
      }
      window.add([event.x, event.y, event.z]);

      if (mounted) {
        setState(() {
          if (_xDataPoints.length >= _maxDataPoints) {
            _xDataPoints.removeAt(0);
            _yDataPoints.removeAt(0);
            _zDataPoints.removeAt(0);
          }
          // Adiciona os novos pontos de dados para o gráfico
          _xDataPoints.add(FlSpot(_dataPointCounter.toDouble(), event.x));
          _yDataPoints.add(FlSpot(_dataPointCounter.toDouble(), event.y));
          _zDataPoints.add(FlSpot(_dataPointCounter.toDouble(), event.z));
          _dataPointCounter++;
        });
      }
    });
  }

  void _stopSensors() {
    _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
  }

  void _startPredictionLoop() {
    predictionTimer?.cancel(); // Cancela timer anterior se houver
    predictionTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_isCollecting || interpreter == null || window.length < 200) return;

      final input = [window];
      // Retornando à forma de saída original que você mencionou
      final output = List.generate(54, (_) => List.filled(3, 0.0));

      try {
        interpreter!.run(input, output);
        // Assumindo que output[0] (o primeiro dos 54 arrays) contém os scores para as 3 classes
        final predictedIndex = _argmax(output[0]);
        
        if (predictedIndex >= 0 && predictedIndex < labelMap.length) {
          final predictedLabel = labelMap[predictedIndex];

          if (predictedIndex != lastPrediction) {
            tts.speak(predictedLabel);
            lastPrediction = predictedIndex;
          }

          final now = DateTime.now().toIso8601String();
          final csvLine = '$now,$predictedLabel';
          history.add(csvLine);

          if (mounted) {
            setState(() {}); // Atualiza a UI com a nova atividade
          }
        } else {
          debugPrint("Índice previsto ($predictedIndex) fora do intervalo para labelMap (tamanho ${labelMap.length}) usando output[0]");
        }
      } catch (e) {
        debugPrint("Erro ao executar inferência: $e");
      }
    });
  }

  void _stopPredictionLoop() {
    predictionTimer?.cancel();
    predictionTimer = null;
  }

  void _toggleCollecting() {
    setState(() {
      _isCollecting = !_isCollecting;
      if (_isCollecting) {
        // Limpa dados antigos do gráfico para um novo começo
        _xDataPoints.clear();
        _yDataPoints.clear();
        _zDataPoints.clear();
        _dataPointCounter = 0;
        lastPrediction = -1; // Reseta a última predição
        if (mounted) setState(() {}); // Atualiza a UI (ex: texto do botão, gráfico limpo)

        _startSensors();
        _startPredictionLoop();
      } else {
        _stopSensors();
        _stopPredictionLoop();
        tts.stop(); // Para o TTS se estiver falando
      }
    });
  }

  int _argmax(List<double> list) {
    if (list.isEmpty) {
      return -1; 
    }
    double maxVal = list[0];
    int index = 0;
    for (int i = 1; i < list.length; i++) {
      if (list[i] > maxVal) {
        maxVal = list[i];
        index = i;
      }
    }
    return index;
  }

  Future<void> _saveCSV() async {
    if (history.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Nenhum histórico para salvar.")),
        );
      }
      return;
    }
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/activity_log_${DateTime.now().millisecondsSinceEpoch}.csv'); // Nome de arquivo único
      await file.writeAsString("Timestamp,Atividade\n${history.join('\n')}"); // Adiciona cabeçalho CSV

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("CSV salvo em ${file.path}")),
      );
    } catch (e) {
      debugPrint('Error saving CSV: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erro ao salvar CSV: $e")),
      );
    }
  }

  Widget _buildAccelerometerChart() {
    double viewMinX;
    double viewMaxX;

    if (!_isCollecting && _xDataPoints.isEmpty) {
        // Se não está coletando e não há dados, mostra uma janela vazia de 0 a _maxDataPoints-1
        viewMinX = 0;
        viewMaxX = (_maxDataPoints - 1).toDouble();
    } else if (_dataPointCounter < _maxDataPoints) {
      viewMinX = 0;
      viewMaxX = (_maxDataPoints - 1).toDouble();
    } else {
      viewMinX = _xDataPoints.isNotEmpty ? _xDataPoints.first.x : _dataPointCounter.toDouble() - _maxDataPoints;
      viewMaxX = _xDataPoints.isNotEmpty ? _xDataPoints.last.x : _dataPointCounter.toDouble() -1;
    }
    
    if (viewMaxX <= viewMinX) {
        viewMaxX = viewMinX + 1; // Garante que maxX é sempre maior que minX
    }

    // Ajustando a escala do eixo Y para um valor mais comum para acelerômetro (m/s^2)
    double minYaxis = -25.0; 
    double maxYaxis = 25.0;  

    return AspectRatio(
      aspectRatio: 1.7, 
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        color: Theme.of(context).cardColor.withOpacity(0.8), 
        child: Padding(
          padding: const EdgeInsets.only(right: 16.0, left: 6.0, top:16, bottom:6),
          child: LineChart(
            LineChartData(
              backgroundColor: Colors.transparent, 
              minY: minYaxis, 
              maxY: maxYaxis, 
              minX: viewMinX, 
              maxX: viewMaxX, 
              lineTouchData: const LineTouchData(enabled: false), 
              titlesData: FlTitlesData(
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 30,
                    getTitlesWidget: (value, meta) {
                      final int labelInterval = (_maxDataPoints ~/ 5).clamp(1, _maxDataPoints);
                      if (value.toInt() % labelInterval == 0) { 
                        return Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text(value.toInt().toString(), style: const TextStyle(color: Colors.grey, fontSize: 10)),
                        );
                      }
                      return const Text('');
                    },
                    interval: 1, 
                  ),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 40, 
                     getTitlesWidget: (value, meta) {
                       // Ajustar o intervalo dos títulos do eixo Y para a nova escala
                       if (value % 5 == 0) { // Mostrar labels de 5 em 5
                         return Text(value.toStringAsFixed(0), style: const TextStyle(color: Colors.grey, fontSize: 10));
                       }
                       return const Text('');
                    },
                    interval: 1, // Verifica cada valor para a condição acima
                  ),
                ),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: true,
                drawHorizontalLine: true,
                getDrawingHorizontalLine: (value) => const FlLine(color: Colors.white12, strokeWidth: 0.8),
                getDrawingVerticalLine: (value) => const FlLine(color: Colors.white12, strokeWidth: 0.8),
              ),
              borderData: FlBorderData(show: true, border: Border.all(color: Colors.white24)),
              lineBarsData: [
                LineChartBarData( // Linha X
                  spots: _xDataPoints,
                  isCurved: true,
                  color: xColor, // Verde
                  barWidth: 2,
                  isStrokeCapRound: true,
                  dotData: const FlDotData(show: false), 
                  belowBarData: BarAreaData(show: false),
                ),
                LineChartBarData( // Linha Y
                  spots: _yDataPoints,
                  isCurved: true,
                  color: yColor, // Amarelo
                  barWidth: 2,
                  isStrokeCapRound: true,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: false),
                ),
                LineChartBarData( // Linha Z
                  spots: _zDataPoints,
                  isCurved: true,
                  color: zColor, // Azul
                  barWidth: 2,
                  isStrokeCapRound: true,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: false),
                ),
              ],
              extraLinesData: ExtraLinesData(
                horizontalLines: [
                  HorizontalLine(y: 0, color: Colors.white30, strokeWidth: 1, dashArray: [5,5]) // Linha no eixo zero
                ]
              ),
            ),
            duration: const Duration(milliseconds: 0), 
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentActivity =
        _isCollecting && lastPrediction >= 0 && lastPrediction < labelMap.length 
        ? labelMap[lastPrediction] 
        : (_isCollecting ? "Coletando..." : "Pausado");

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reconhecimento de Atividades'),
      ),
      body: SingleChildScrollView( 
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Atividade Atual:',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              Card(
                elevation: 8.0,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    currentActivity, 
                    style: TextStyle(
                      fontSize: 32, 
                      color: _isCollecting && lastPrediction == -1 ? Colors.grey : Colors.white)
                    ),
                ),
              ),
              const SizedBox(height: 30),
              Text('Dados do Acelerômetro (X, Y, Z)', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 5),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(children: [Container(width: 10, height: 10, color: xColor), const SizedBox(width: 4), const Text('X')]), // Legenda X Verde
                  const SizedBox(width: 10),
                  Row(children: [Container(width: 10, height: 10, color: yColor), const SizedBox(width: 4), const Text('Y')]), // Legenda Y Amarelo
                  const SizedBox(width: 10),
                  Row(children: [Container(width: 10, height: 10, color: zColor), const SizedBox(width: 4), const Text('Z')]), // Legenda Z Azul
                ],
              ),
              const SizedBox(height: 10),
              _buildAccelerometerChart(), 
              const SizedBox(height: 30),
              // Botão Salvar CSV
              ElevatedButton(
                onPressed: _saveCSV,
                child: const Text("Salvar histórico em CSV"),
              ),
              const SizedBox(height: 20), // Espaço entre os botões
              // Botão Iniciar/Parar Coleta
              ElevatedButton.icon(
                icon: Icon(_isCollecting ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                label: Text(_isCollecting ? "Parar Coleta" : "Iniciar Coleta"),
                onPressed: _toggleCollecting,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isCollecting ? Colors.redAccent : Colors.greenAccent, // Mantido para destaque do botão de controle
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                  textStyle: const TextStyle(fontSize: 16)
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}