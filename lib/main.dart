import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart'; 
import 'package:pdf/pdf.dart'; 
import 'package:pdf/widgets.dart' as pw; 
import 'package:printing/printing.dart'; 
import 'package:shared_preferences/shared_preferences.dart';

// --- DATA MODELS ---
class Student {
  final String admNumber;
  final String name;
  final String? groupName;
  Student({required this.admNumber, required this.name, this.groupName});
}

class TransactionLog {
  final int? id; 
  final String toolName;
  final String issuedTo;
  final DateTime timeBorrowed;
  final String? contactInfo; 

  TransactionLog({this.id, required this.toolName, required this.issuedTo, required this.timeBorrowed, this.contactInfo});
}

class ManualItemCtrl {
  final nameCtrl = TextEditingController();
  final qtyCtrl = TextEditingController(text: '1');
  void dispose() { nameCtrl.dispose(); qtyCtrl.dispose(); }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://htvyekhsxzctvlltqtsq.supabase.co', 
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh0dnlla2hzeHpjdHZsbHRxdHNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzEwMDA1NjMsImV4cCI6MjA4NjU3NjU2M30.F8DUOG6q9ynw1IbIkn1Q1GJfICL_XvJKb9V-AlPCuEw',
  );

  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => LabState())],
      child: const KistLabApp(),
    ),
  );
}

class KistLabApp extends StatelessWidget {
  const KistLabApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'KIST Lab Ledger',
      theme: ThemeData(
        useMaterial3: true,
        textTheme: GoogleFonts.outfitTextTheme(),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF003366)),
        scaffoldBackgroundColor: const Color(0xFFF0F2F5),
      ),
      home: const DashboardScreen(),
    );
  }
}

// --- STATE MANAGEMENT ---
class LabState extends ChangeNotifier {
  final _supabase = Supabase.instance.client;
  
  List<TransactionLog> activeLoans = [];
  List<Map<String, dynamic>> pendingRequests = [];

  Map<String, dynamic>? selectedRequest;
  Set<String> selectedToolsToApprove = {};
  String? selectedReturnBorrower;
  Set<TransactionLog> selectedToolsToReturn = {};

  bool isManualFormActive = false;
  final nameCtrl = TextEditingController();
  final admCtrl = TextEditingController();
  final classCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  final keyCtrl = TextEditingController();
  List<ManualItemCtrl> manualItems = [ManualItemCtrl()];

  StreamSubscription? _requestSubscription;
  RealtimeChannel? _ledgerSyncChannel;
  Timer? _syncTimer;
  bool isSyncing = false;
  int pendingOfflineActions = 0;

  LabState() { _init(); }

  Future<void> _init() async {
    await refresh();
    listenToLiveQueue();
    _setupMultiDeviceSync(); 
    _checkOfflineQueueSize();
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) => _syncOfflineQueue());
  }

  void _setupMultiDeviceSync() {
    _ledgerSyncChannel = _supabase.channel('public:transaction_logs');
    _ledgerSyncChannel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'transaction_logs',
      callback: (payload) {
        if (!isSyncing) refresh(); 
      }
    ).subscribe();
  }

  void addManualItem() { manualItems.add(ManualItemCtrl()); notifyListeners(); }
  void removeManualItem(int index) { manualItems[index].dispose(); manualItems.removeAt(index); notifyListeners(); }

  Future<void> _checkOfflineQueueSize() async {
    final prefs = await SharedPreferences.getInstance();
    pendingOfflineActions = (prefs.getStringList('offline_queue') ?? []).length;
    notifyListeners();
  }

  Future<void> _executeOrQueue(String table, String action, dynamic payload) async {
    try {
      if (action == 'INSERT') await _supabase.from(table).insert(payload);
      if (action == 'UPDATE') await _supabase.from(table).update(payload['data']).eq(payload['col'], payload['val']);
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      final queue = prefs.getStringList('offline_queue') ?? [];
      queue.add(jsonEncode({'table': table, 'action': action, 'payload': payload}));
      await prefs.setStringList('offline_queue', queue);
      _checkOfflineQueueSize();
    }
  }

  Future<void> _syncOfflineQueue() async {
    if (isSyncing) return;
    isSyncing = true;
    final prefs = await SharedPreferences.getInstance();
    final queue = prefs.getStringList('offline_queue') ?? [];
    if (queue.isEmpty) { isSyncing = false; return; }

    List<String> failedQueue = [];
    for (var item in queue) {
      try {
        final map = jsonDecode(item);
        if (map['action'] == 'INSERT') await _supabase.from(map['table']).insert(map['payload']);
        if (map['action'] == 'UPDATE') await _supabase.from(map['table']).update(map['payload']['data']).eq(map['payload']['col'], map['payload']['val']);
      } catch (e) { failedQueue.add(item); }
    }
    await prefs.setStringList('offline_queue', failedQueue);
    _checkOfflineQueueSize();
    isSyncing = false;
    if (failedQueue.isEmpty) await refresh(); 
  }

  void listenToLiveQueue() {
    _requestSubscription?.cancel();
    _requestSubscription = _supabase.from('tool_requests').stream(primaryKey: ['id']).eq('status', 'PENDING').order('created_at', ascending: true).listen((data) {
      pendingRequests = data;
      if (selectedRequest != null && !data.any((r) => r['id'] == selectedRequest!['id'])) selectedRequest = null;
      notifyListeners();
    }, onError: (_) {}); 
  }

  Future<void> refresh() async {
    try {
      final loansData = await _supabase.from('transaction_logs').select().eq('is_returned', false).order('time_borrowed', ascending: false);
      activeLoans = loansData.map((l) => TransactionLog(
        id: l['id'], toolName: l['tool_name'], issuedTo: l['issued_to'] ?? 'Unknown', timeBorrowed: DateTime.parse(l['time_borrowed']), contactInfo: l['contact_info'],
      )).toList();
      notifyListeners();
    } catch (e) { debugPrint("Offline Mode Active."); }
  }

  void selectRequestForReview(Map<String, dynamic> request) {
    selectedRequest = request;
    selectedToolsToApprove = (request['tools_requested'] ?? []).map<String>((t) => t['tool'].toString()).toSet();
    isManualFormActive = false; selectedReturnBorrower = null; notifyListeners();
  }

  void activateManualForm() {
    isManualFormActive = true; selectedRequest = null; selectedReturnBorrower = null;
    nameCtrl.clear(); admCtrl.clear(); classCtrl.clear(); phoneCtrl.clear(); keyCtrl.clear();
    for(var item in manualItems) { item.dispose(); }
    manualItems = [ManualItemCtrl()];
    notifyListeners();
  }

  void selectReturnBorrower(String borrower) {
    selectedReturnBorrower = borrower; selectedRequest = null; isManualFormActive = false;
    selectedToolsToReturn = activeLoans.where((l) => l.issuedTo == borrower).toSet();
    notifyListeners();
  }

  void toggleRequestToolSelection(String toolName) {
    if (selectedToolsToApprove.contains(toolName)) selectedToolsToApprove.remove(toolName);
    else selectedToolsToApprove.add(toolName);
    notifyListeners();
  }

  void toggleReturnToolSelection(TransactionLog log) {
    if (selectedToolsToReturn.contains(log)) selectedToolsToReturn.remove(log);
    else selectedToolsToReturn.add(log);
    notifyListeners();
  }

  Future<void> approveSelectedQRRequest() async {
    if (selectedRequest == null || selectedToolsToApprove.isEmpty) return;
    final request = selectedRequest!;
    
    pendingRequests.removeWhere((req) => req['id'] == request['id']);
    
    for (var tool in selectedToolsToApprove) {
      activeLoans.insert(0, TransactionLog(toolName: tool, issuedTo: "${request['student_name']} (${request['adm_number'] ?? 'QR'})", timeBorrowed: DateTime.now(), contactInfo: request['phone_number']));
    }

    _executeOrQueue('tool_requests', 'UPDATE', {'data': {'status': 'ISSUED'}, 'col': 'id', 'val': request['id']});
    for (var toolName in selectedToolsToApprove) {
      _executeOrQueue('transaction_logs', 'INSERT', {
        'tool_name': toolName, 'student_name': request['student_name'], 'issued_to': "${request['student_name']} (${request['adm_number'] ?? 'QR'})",
        'contact_info': request['phone_number'], 'time_borrowed': DateTime.now().toIso8601String(), 'is_returned': false, 'status': 'GOOD' 
      });
    }
    
    selectedRequest = null; selectedToolsToApprove.clear(); notifyListeners();
  }

  Future<void> submitManualForm() async {
    if (nameCtrl.text.isEmpty) return;
    final studentName = nameCtrl.text.trim();
    final admNumber = admCtrl.text.trim();
    final phone = phoneCtrl.text.trim();
    final lockerKey = keyCtrl.text.trim();
    
    List<String> itemsToIssue = [];
    if (lockerKey.isNotEmpty) itemsToIssue.add("Locker Key: $lockerKey");

    for (var item in manualItems) {
      final name = item.nameCtrl.text.trim();
      final qty = int.tryParse(item.qtyCtrl.text.trim()) ?? 1;
      if (name.isNotEmpty && qty > 0) {
        for (int i = 0; i < qty; i++) itemsToIssue.add(name);
      }
    }

    if (itemsToIssue.isEmpty) return;

    for (var tool in itemsToIssue) {
      final issueString = admNumber.isNotEmpty ? "$studentName ($admNumber)" : studentName;
      activeLoans.insert(0, TransactionLog(toolName: tool, issuedTo: issueString, timeBorrowed: DateTime.now(), contactInfo: phone));
      _executeOrQueue('transaction_logs', 'INSERT', {
        'tool_name': tool, 'student_name': studentName, 'issued_to': issueString, 'contact_info': phone,
        'time_borrowed': DateTime.now().toIso8601String(), 'is_returned': false, 'status': 'GOOD' 
      });
    }

    isManualFormActive = false; notifyListeners();
  }

  Future<void> confirmReturns() async {
    if (selectedReturnBorrower == null || selectedToolsToReturn.isEmpty) return;
    activeLoans.removeWhere((loan) => selectedToolsToReturn.contains(loan));

    for (var loan in selectedToolsToReturn) {
      if (loan.id != null) {
        _executeOrQueue('transaction_logs', 'UPDATE', {
          'data': {'is_returned': true, 'time_returned': DateTime.now().toIso8601String()}, 'col': 'id', 'val': loan.id
        });
      }
    }
    selectedReturnBorrower = null; selectedToolsToReturn.clear(); notifyListeners();
  }

  Future<void> sendSMSReminder(String? phone, String borrowerName) async {
    if (phone == null || phone.isEmpty) return;
    final Uri smsUri = Uri.parse('sms:$phone?body=Hello $borrowerName, you still have unreturned tools belonging to the KIST Mechatronics Lab. Please return them immediately. Thank you.');
    if (await canLaunchUrl(smsUri)) await launchUrl(smsUri);
  }

  Future<void> generatePDF() async {
    final pdf = pw.Document();
    final groupedLoans = <String, List<TransactionLog>>{};
    for (var loan in activeLoans) { groupedLoans.putIfAbsent(loan.issuedTo, () => []).add(loan); }

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('KIST Mechatronics Lab', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
              pw.Text('Unreturned Tools Liability Report', style: const pw.TextStyle(fontSize: 18, color: PdfColors.red)),
              pw.SizedBox(height: 10),
              pw.Text('Generated: ${DateTime.now().toString().split('.')[0]}'),
              pw.SizedBox(height: 20),
              pw.TableHelper.fromTextArray(
                headers: ['Student Details', 'Contact', 'Tools Still Owed'],
                data: groupedLoans.entries.map((e) => [e.key, e.value.first.contactInfo ?? 'N/A', e.value.map((l) => "• ${l.toolName}").join("\n")]).toList(),
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
                headerDecoration: const pw.BoxDecoration(color: PdfColors.blue900),
              ),
            ],
          );
        },
      ),
    );
    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => pdf.save(), name: 'Missing_Tools_Report.pdf');
  }

  @override
  void dispose() {
    _requestSubscription?.cancel();
    _ledgerSyncChannel?.unsubscribe();
    _syncTimer?.cancel();
    nameCtrl.dispose(); admCtrl.dispose(); classCtrl.dispose(); phoneCtrl.dispose(); keyCtrl.dispose();
    for (var item in manualItems) { item.dispose(); }
    super.dispose();
  }
}

// --- RESPONSIVE UI DASHBOARD ---
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with SingleTickerProviderStateMixin {
  late TabController _mobileTabCtrl;

  @override
  void initState() {
    super.initState();
    _mobileTabCtrl = TabController(length: 3, vsync: this);
  }

  // NEW: Centralized Navigation Method
  void _navigateToTab(int index) {
    if (_mobileTabCtrl.index != index) {
      _mobileTabCtrl.animateTo(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    final isDesktop = MediaQuery.of(context).size.width > 900;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text("KIST Ledger", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(width: 10),
            if (state.pendingOfflineActions > 0)
              Chip(
                backgroundColor: Colors.orange,
                label: const Text("Offline", style: TextStyle(color: Colors.white, fontSize: 10)),
                avatar: const Icon(Icons.wifi_off, color: Colors.white, size: 14),
                visualDensity: VisualDensity.compact,
              )
          ],
        ),
        backgroundColor: const Color(0xFF003366),
        actions: [
          IconButton(onPressed: () => context.read<LabState>().refresh(), icon: const Icon(Icons.refresh, color: Colors.white))
        ],
      ),
      body: isDesktop 
          ? Row(children: [
              Expanded(flex: 3, child: SelectionPanel(onNavigate: _navigateToTab)),
              const VerticalDivider(width: 1),
              Expanded(flex: 5, child: CenterReviewPanel(onNavigate: _navigateToTab)), 
              const VerticalDivider(width: 1),
              Expanded(flex: 4, child: ActionPanel(onNavigate: _navigateToTab)), 
            ])
          : TabBarView(
              controller: _mobileTabCtrl,
              physics: const NeverScrollableScrollPhysics(), // Prevent swipe
              children: [
                SelectionPanel(onNavigate: _navigateToTab),
                CenterReviewPanel(onNavigate: _navigateToTab),
                ActionPanel(onNavigate: _navigateToTab),
              ],
            ),
      bottomNavigationBar: isDesktop ? null : Container(
        color: const Color(0xFF003366),
        child: TabBar(
          controller: _mobileTabCtrl,
          indicatorColor: Colors.orange,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          tabs: const [
            Tab(icon: Icon(Icons.group_add), text: "Issue"),
            Tab(icon: Icon(Icons.fact_check), text: "Review"),
            Tab(icon: Icon(Icons.inventory_2), text: "Returns"),
          ],
        ),
      ),
    );
  }
}

// --- QUICK SUMMARY DIALOG FOR END OF LAB ---
void showEndTrackerDialog(BuildContext context, LabState state) {
  final groupedLoans = <String, List<TransactionLog>>{};
  for (var loan in state.activeLoans) { groupedLoans.putIfAbsent(loan.issuedTo, () => []).add(loan); }

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text("End of Lab Tracker", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF003366))),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: groupedLoans.isEmpty 
          ? const Center(child: Text("All tools and keys returned. Great job!", style: TextStyle(color: Colors.green, fontSize: 18)))
          : ListView(
              children: groupedLoans.entries.map((e) {
                return Card(
                  color: Colors.red[50],
                  child: ListTile(
                    title: Text(e.key, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(e.value.map((l) => l.toolName).join(", ")),
                    trailing: Text("${e.value.length} items", style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                  ),
                );
              }).toList(),
            ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CLOSE", style: TextStyle(fontSize: 16)))
      ],
    ),
  );
}

// --- PANELS (Updated to accept the navigation callback) ---

class SelectionPanel extends StatelessWidget {
  final Function(int)? onNavigate;
  const SelectionPanel({super.key, this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    final isDesktop = MediaQuery.of(context).size.width > 900;

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(labelColor: Color(0xFF003366), tabs: [Tab(text: "QR QUEUE"), Tab(text: "MANUAL ISSUE")]),
          Expanded(
            child: TabBarView(
              children: [
                state.pendingRequests.isEmpty 
                  ? const Center(child: Text("Queue is empty", style: TextStyle(color: Colors.grey))) 
                  : ListView.builder(
                      itemCount: state.pendingRequests.length,
                      itemBuilder: (context, i) {
                        final req = state.pendingRequests[i];
                        final isSelected = state.selectedRequest?['id'] == req['id'];
                        return Card(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          color: isSelected ? Colors.orange[50] : Colors.white,
                          child: ListTile(
                            title: Text(req['student_name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text("${req['class_name']}\nItems: ${(req['tools_requested'] as List).length}"),
                            isThreeLine: true,
                            trailing: ElevatedButton(
                              onPressed: () {
                                state.selectRequestForReview(req);
                                if (!isDesktop && onNavigate != null) onNavigate!(1); // Jump to Center Tab
                              },
                              style: ElevatedButton.styleFrom(backgroundColor: isSelected ? const Color(0xFF003366) : Colors.blueGrey, foregroundColor: Colors.white),
                              child: Text(isSelected ? "REVIEWING" : "REVIEW"),
                            ),
                          ),
                        );
                      },
                    ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.person_add_alt_1_outlined, size: 60, color: Colors.blueGrey[200]),
                        const SizedBox(height: 10),
                        ElevatedButton.icon(
                          onPressed: () {
                            state.activateManualForm();
                            if (!isDesktop && onNavigate != null) onNavigate!(1); // Jump to Center Tab
                          },
                          icon: const Icon(Icons.edit_document),
                          label: const Text("CREATE MANUAL RECORD"),
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF003366), foregroundColor: Colors.white),
                        )
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class CenterReviewPanel extends StatelessWidget {
  final Function(int)? onNavigate;
  const CenterReviewPanel({super.key, this.onNavigate});

  InputDecoration _inputDecor(String label, IconData icon) {
    return InputDecoration(
      labelText: label, prefixIcon: Icon(icon, color: Colors.blueGrey),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      filled: true, fillColor: Colors.grey[50], contentPadding: const EdgeInsets.symmetric(vertical: 10)
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    final isDesktop = MediaQuery.of(context).size.width > 900;
    
    if (state.isManualFormActive) {
      return Container(
        color: Colors.white, padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Manual Issue", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF003366))),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(controller: state.nameCtrl, decoration: _inputDecor("Student Full Name *", Icons.person)),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: TextField(controller: state.admCtrl, decoration: _inputDecor("Adm Number", Icons.badge))),
                      const SizedBox(width: 10),
                      Expanded(child: TextField(controller: state.classCtrl, decoration: _inputDecor("Class", Icons.class_))),
                    ]),
                    const SizedBox(height: 10),
                    TextField(controller: state.phoneCtrl, decoration: _inputDecor("Phone Number", Icons.phone)),
                    const SizedBox(height: 20),
                    const Text("Locker Keys:", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.deepOrange)),
                    const SizedBox(height: 8),
                    TextField(controller: state.keyCtrl, decoration: _inputDecor("Key Tag (e.g. S21)", Icons.vpn_key).copyWith(fillColor: Colors.orange[50])),
                    const SizedBox(height: 20),
                    const Text("Tools Issued:", style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    ...state.manualItems.asMap().entries.map((entry) {
                      final index = entry.key; final item = entry.value;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(flex: 3, child: TextField(controller: item.nameCtrl, decoration: _inputDecor("Tool Name", Icons.build))),
                            const SizedBox(width: 8),
                            Expanded(flex: 1, child: TextField(controller: item.qtyCtrl, keyboardType: TextInputType.number, textAlign: TextAlign.center, decoration: _inputDecor("Qty", Icons.numbers))),
                            IconButton(icon: const Icon(Icons.remove_circle, color: Colors.redAccent), onPressed: state.manualItems.length > 1 ? () => state.removeManualItem(index) : null)
                          ],
                        )
                      );
                    }),
                    TextButton.icon(onPressed: () => state.addManualItem(), icon: const Icon(Icons.add_circle, color: Colors.green), label: const Text("Add Another Tool", style: TextStyle(color: Colors.green))),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: double.infinity, height: 50,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.save), label: const Text("SAVE & ISSUE", style: TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                onPressed: () { 
                  state.submitManualForm(); 
                  if (!isDesktop && onNavigate != null) onNavigate!(2); // Jump to Returns Tab
                },
              ),
            )
          ],
        ),
      );
    }

    if (state.selectedRequest != null) {
      final req = state.selectedRequest!;
      final List requestedTools = req['tools_requested'] ?? [];
      return Container(
        color: Colors.white, padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Review QR Request", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF003366))),
            const Divider(),
            Text("Student: ${req['student_name']}", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text("ADM: ${req['adm_number'] ?? 'N/A'} | Class: ${req['class_name']}"),
            const SizedBox(height: 10),
            Container(padding: const EdgeInsets.all(10), color: Colors.orange[50], child: const Text("Uncheck any tools you are NOT giving.")),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                itemCount: requestedTools.length,
                itemBuilder: (context, i) {
                  final toolName = requestedTools[i]['tool'].toString();
                  final isChecked = state.selectedToolsToApprove.contains(toolName);
                  return CheckboxListTile(
                    title: Text(toolName, style: TextStyle(decoration: isChecked ? null : TextDecoration.lineThrough)),
                    value: isChecked, activeColor: Colors.green, onChanged: (val) => state.toggleRequestToolSelection(toolName),
                  );
                },
              ),
            ),
            SizedBox(
              width: double.infinity, height: 50,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.check_circle), label: Text("CONFIRM ISSUE (${state.selectedToolsToApprove.length})"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                onPressed: state.selectedToolsToApprove.isEmpty ? null : () { 
                  state.approveSelectedQRRequest();
                  if (!isDesktop && onNavigate != null) onNavigate!(2); // Jump to Returns Tab
                },
              ),
            )
          ],
        ),
      );
    }

    if (state.selectedReturnBorrower != null) {
      final borrower = state.selectedReturnBorrower!;
      final borrowerLoans = state.activeLoans.where((l) => l.issuedTo == borrower).toList();
      return Container(
        color: Colors.white, padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Process Returns", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.green)),
            const Divider(),
            Text("Borrower: $borrower", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Container(padding: const EdgeInsets.all(10), color: Colors.red[50], child: const Text("Uncheck items NOT returned.")),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                itemCount: borrowerLoans.length,
                itemBuilder: (context, i) {
                  final loan = borrowerLoans[i];
                  final isChecked = state.selectedToolsToReturn.contains(loan);
                  return CheckboxListTile(
                    title: Text(loan.toolName, style: const TextStyle(fontWeight: FontWeight.bold)),
                    value: isChecked, activeColor: Colors.green, onChanged: (val) => state.toggleReturnToolSelection(loan),
                  );
                },
              ),
            ),
            SizedBox(
              width: double.infinity, height: 50,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.keyboard_return), label: Text("CONFIRM RETURN (${state.selectedToolsToReturn.length})"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                onPressed: state.selectedToolsToReturn.isEmpty ? null : () {
                   state.confirmReturns();
                   if (!isDesktop && onNavigate != null) onNavigate!(2); // Jump back to Returns List
                },
              ),
            )
          ],
        ),
      );
    }

    return Container(color: Colors.white, child: Center(child: Text("Select an action to review.", style: TextStyle(color: Colors.grey[500]))));
  }
}

class ActionPanel extends StatelessWidget {
  final Function(int)? onNavigate;
  const ActionPanel({super.key, this.onNavigate});
  
  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    final isDesktop = MediaQuery.of(context).size.width > 900;
    
    final groupedLoans = <String, List<TransactionLog>>{};
    for (var loan in state.activeLoans) { groupedLoans.putIfAbsent(loan.issuedTo, () => []).add(loan); }
    final borrowers = groupedLoans.keys.toList();

    return Container(
      color: Colors.grey[50], 
      child: Column(
        children: [
          Container(
            color: const Color(0xFF003366),
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("UNRETURNED", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.visibility, color: Colors.cyanAccent),
                      tooltip: "End of Lab Tracker",
                      onPressed: state.activeLoans.isEmpty ? null : () => showEndTrackerDialog(context, state),
                    ),
                    IconButton(
                      icon: const Icon(Icons.picture_as_pdf, color: Colors.redAccent),
                      tooltip: "Export PDF",
                      onPressed: state.activeLoans.isEmpty ? null : () => state.generatePDF(),
                    ),
                  ],
                )
              ],
            ),
          ),
          Expanded(
            child: borrowers.isEmpty 
            ? const Center(child: Text("All items returned.", style: TextStyle(color: Colors.grey)))
            : ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 20),
                itemCount: borrowers.length,
                itemBuilder: (context, i) {
                  final borrowerName = borrowers[i];
                  final loans = groupedLoans[borrowerName]!;
                  final isSelected = state.selectedReturnBorrower == borrowerName;
                  String? contactNumber = loans.firstWhere((l) => l.contactInfo != null && l.contactInfo!.isNotEmpty, orElse: () => loans.first).contactInfo;

                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.green.shade50 : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isSelected ? Colors.green : Colors.grey.shade300, width: isSelected ? 2 : 1),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(borrowerName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                              if (contactNumber != null)
                                IconButton(
                                  padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                                  icon: const Icon(Icons.sms, color: Colors.blue, size: 20),
                                  onPressed: () => state.sendSMSReminder(contactNumber, borrowerName.split(' ')[0]),
                                )
                            ],
                          ),
                          Text("${loans.length} item(s) pending", style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity, height: 35,
                            child: ElevatedButton(
                              onPressed: () { 
                                state.selectReturnBorrower(borrowerName);
                                if (!isDesktop && onNavigate != null) onNavigate!(1); // Jump to Center Review Tab
                              }, 
                              style: ElevatedButton.styleFrom(backgroundColor: isSelected ? Colors.green : Colors.grey.shade100, foregroundColor: isSelected ? Colors.white : Colors.black87, elevation: 0),
                              child: Text(isSelected ? "REVIEWING..." : "PROCESS RETURN"),
                            )
                          )
                        ],
                      ),
                    ),
                  );
                },
              ),
          )
        ],
      ),
    );
  }
}