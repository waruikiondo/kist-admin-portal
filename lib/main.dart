import 'dart:async'; // Required for StreamSubscription
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// --- DATA MODELS ---
class Tool {
  final String id;
  final String name;
  final String category;
  bool isAvailable;
  Tool({required this.id, required this.name, required this.category, this.isAvailable = true});
}

class Student {
  final String admNumber;
  final String name;
  final String? groupName;
  Student({required this.admNumber, required this.name, this.groupName});
}

class LabGroup {
  final String name;
  LabGroup({required this.name});
}

class TransactionLog {
  final int id;
  final String toolName;
  final String issuedTo;
  final bool isGroupIssue;
  final DateTime timeBorrowed;
  TransactionLog({required this.id, required this.toolName, required this.issuedTo, this.isGroupIssue = false, required this.timeBorrowed});
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
      title: 'KIST Mechatronics Lab',
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
  
  List<Tool> tools = [];
  List<Student> students = [];
  List<LabGroup> groups = [LabGroup(name: "Bench 1"), LabGroup(name: "Bench 2"), LabGroup(name: "Bench 3"), LabGroup(name: "Bench 4")];
  List<TransactionLog> activeLoans = [];
  List<Map<String, dynamic>> pendingRequests = [];

  Student? selectedStudent;
  LabGroup? selectedGroup;
  List<Tool> selectedTools = [];

  // Persistent stream subscription
  StreamSubscription? _requestSubscription;

  LabState() {
    _init();
  }

  Future<void> _init() async {
    await refresh();
    
    // Seed data if database is fresh
    if (tools.isEmpty) {
      debugPrint("DB: Seeding initial tools...");
      await _supabase.from('tools').insert([
        {'name': 'Fluke Multimeter', 'category': 'Electrical', 'is_available': true},
        {'name': 'Screwdriver Set', 'category': 'Hand', 'is_available': true},
        {'name': 'Soldering Station', 'category': 'Electrical', 'is_available': true},
      ]);
      await refresh();
    }
    
    listenToLiveQueue();
  }

  void listenToLiveQueue() {
    debugPrint("REALTIME: Connecting to tool_requests stream...");
    
    _requestSubscription?.cancel(); // Clear old listeners if any

    _requestSubscription = _supabase
        .from('tool_requests')
        .stream(primaryKey: ['id'])
        .eq('status', 'PENDING')
        .order('created_at', ascending: true)
        .listen((data) {
          debugPrint("REALTIME: Update received! Active Pending: ${data.length}");
          pendingRequests = data;
          notifyListeners();
        }, onError: (error) {
          debugPrint("REALTIME ERROR: $error");
        });
  }

  Future<void> refresh() async {
    try {
      final toolsData = await _supabase.from('tools').select().order('name');
      tools = toolsData.map((t) => Tool(id: t['id'].toString(), name: t['name'], category: t['category'] ?? 'General', isAvailable: t['is_available'] ?? true)).toList();

      final studentsData = await _supabase.from('students').select().order('name');
      students = studentsData.map((s) => Student(admNumber: s['adm_number'], name: s['name'])).toList();

      final loansData = await _supabase.from('transaction_logs').select().eq('is_returned', false).order('time_borrowed', ascending: false);
      activeLoans = loansData.map((l) => TransactionLog(id: l['id'], toolName: l['tool_name'], issuedTo: l['issued_to'] ?? 'Unknown', isGroupIssue: l['is_group_issue'] ?? false, timeBorrowed: DateTime.parse(l['time_borrowed']))).toList();

      notifyListeners();
    } catch (e) {
      debugPrint("REFRESH ERROR: $e");
    }
  }

  void selectStudent(Student s) { selectedStudent = s; selectedGroup = null; notifyListeners(); }
  void selectGroup(LabGroup g) { selectedGroup = g; selectedStudent = null; notifyListeners(); }
  void toggleToolSelection(Tool tool) { selectedTools.contains(tool) ? selectedTools.remove(tool) : selectedTools.add(tool); notifyListeners(); }

  Future<void> issueTools() async {
    if ((selectedStudent == null && selectedGroup == null) || selectedTools.isEmpty) return;
    final issuedToName = selectedStudent?.name ?? selectedGroup?.name ?? 'Unknown';
    final isGroup = selectedGroup != null;

    for (var tool in selectedTools) {
      await _supabase.from('transaction_logs').insert({'tool_name': tool.name, 'issued_to': issuedToName, 'is_group_issue': isGroup, 'time_borrowed': DateTime.now().toIso8601String(), 'is_returned': false, 'status': 'GOOD'});
      await _supabase.from('tools').update({'is_available': false}).eq('id', tool.id);
    }
    selectedStudent = null; selectedGroup = null; selectedTools = [];
    await refresh();
  }

  Future<void> approveQRRequest(Map<String, dynamic> request) async {
    // 1. Mark request as issued
    await _supabase.from('tool_requests').update({'status': 'ISSUED'}).eq('id', request['id']);
    
    final List requestedTools = request['tools_requested'] ?? [];
    for (var reqTool in requestedTools) {
      final toolName = reqTool['tool'];
      
      // Match with local tool inventory
      final tool = tools.firstWhere((t) => t.name == toolName && t.isAvailable, 
          orElse: () => Tool(id: '', name: toolName, category: 'Requested'));
      
      await _supabase.from('transaction_logs').insert({
        'tool_name': toolName,
        'issued_to': "${request['student_name']} (QR)",
        'is_group_issue': false,
        'time_borrowed': DateTime.now().toIso8601String(),
        'is_returned': false,
        'status': 'GOOD'
      });

      if (tool.id.isNotEmpty) {
        await _supabase.from('tools').update({'is_available': false}).eq('id', tool.id);
      }
    }
    await refresh();
  }

  Future<void> returnItem(TransactionLog log) async {
    await _supabase.from('transaction_logs').update({'is_returned': true, 'time_returned': DateTime.now().toIso8601String()}).eq('id', log.id);
    await _supabase.from('tools').update({'is_available': true}).eq('name', log.toolName);
    await refresh();
  }

  @override
  void dispose() {
    _requestSubscription?.cancel();
    super.dispose();
  }
}

// --- UI COMPONENTS ---
// (DashboardScreen, SelectionPanel, ToolGridPanel, ActionPanel remain largely the same, but ensure they use context.watch<LabState>())

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width > 900;
    return Scaffold(
      appBar: AppBar(
        title: const Text("KIST Mechatronics Lab", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF003366),
        actions: [
          IconButton(onPressed: () => context.read<LabState>().refresh(), icon: const Icon(Icons.refresh, color: Colors.white))
        ],
      ),
      body: isDesktop ? const DesktopLayout() : TabBarView(controller: _tabController, children: const [SelectionPanel(), ToolGridPanel(), ActionPanel()]),
      bottomNavigationBar: isDesktop ? null : Container(
        color: const Color(0xFF003366),
        child: TabBar(controller: _tabController, indicatorColor: Colors.orange, labelColor: Colors.white, unselectedLabelColor: Colors.white60, tabs: const [
          Tab(icon: Icon(Icons.qr_code), text: "Queue"),
          Tab(icon: Icon(Icons.build), text: "Inventory"),
          Tab(icon: Icon(Icons.shopping_cart), text: "Issue"),
        ]),
      ),
    );
  }
}

class DesktopLayout extends StatelessWidget {
  const DesktopLayout({super.key});
  @override
  Widget build(BuildContext context) {
    return const Row(children: [
      Expanded(flex: 3, child: SelectionPanel()),
      VerticalDivider(width: 1),
      Expanded(flex: 5, child: ToolGridPanel()),
      VerticalDivider(width: 1),
      Expanded(flex: 3, child: ActionPanel()),
    ]);
  }
}

class SelectionPanel extends StatelessWidget {
  const SelectionPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            labelColor: Color(0xFF003366),
            tabs: [Tab(text: "QR QUEUE"), Tab(text: "STUDENTS")],
          ),
          Expanded(
            child: TabBarView(
              children: [
                // QR QUEUE TAB
                state.pendingRequests.isEmpty 
                  ? const Center(child: Text("No incoming requests")) 
                  : ListView.builder(
                      itemCount: state.pendingRequests.length,
                      itemBuilder: (context, i) {
                        final req = state.pendingRequests[i];
                        return Card(
                          margin: const EdgeInsets.all(8),
                          color: Colors.orange[50],
                          child: ListTile(
                            title: Text(req['student_name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text("Items: ${(req['tools_requested'] as List).length}"),
                            trailing: ElevatedButton(
                              onPressed: () => state.approveQRRequest(req),
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                              child: const Text("APPROVE"),
                            ),
                          ),
                        );
                      },
                    ),
                // STUDENTS TAB
                ListView.builder(
                  itemCount: state.students.length,
                  itemBuilder: (context, i) {
                    final s = state.students[i];
                    return ListTile(
                      selected: state.selectedStudent?.admNumber == s.admNumber,
                      title: Text(s.name),
                      onTap: () => state.selectStudent(s),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ToolGridPanel extends StatelessWidget {
  const ToolGridPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 10, mainAxisSpacing: 10),
      itemCount: state.tools.length,
      itemBuilder: (context, i) {
        final t = state.tools[i];
        final isSel = state.selectedTools.contains(t);
        return InkWell(
          onTap: t.isAvailable ? () => state.toggleToolSelection(t) : null,
          child: Container(
            decoration: BoxDecoration(
              color: t.isAvailable ? (isSel ? const Color(0xFF003366) : Colors.white) : Colors.grey[300],
              border: Border.all(color: Colors.grey[300]!),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.build, color: isSel ? Colors.white : Colors.black),
                Text(t.name, style: TextStyle(color: isSel ? Colors.white : Colors.black, fontSize: 12), textAlign: TextAlign.center),
                if (!t.isAvailable) const Text("OUT", style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class ActionPanel extends StatelessWidget {
  const ActionPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: ElevatedButton(
            onPressed: (state.selectedTools.isNotEmpty && (state.selectedStudent != null || state.selectedGroup != null)) 
              ? () => state.issueTools() : null,
            style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50), backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text("CONFIRM ISSUE"),
          ),
        ),
        const Divider(),
        const Text("ACTIVE LOANS", style: TextStyle(fontWeight: FontWeight.bold)),
        Expanded(
          child: ListView.builder(
            itemCount: state.activeLoans.length,
            itemBuilder: (context, i) {
              final loan = state.activeLoans[i];
              return ListTile(
                title: Text(loan.toolName),
                subtitle: Text("To: ${loan.issuedTo}"),
                trailing: TextButton(onPressed: () => state.returnItem(loan), child: const Text("RETURN")),
              );
            },
          ),
        )
      ],
    );
  }
}