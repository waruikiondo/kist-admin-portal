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

  TransactionLog({
    required this.id,
    required this.toolName,
    required this.issuedTo,
    this.isGroupIssue = false,
    required this.timeBorrowed,
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize Supabase (Cloud) - THE ONLY DATABASE WE NEED
  await Supabase.initialize(
    url: 'YOUR_SUPABASE_URL_HERE', 
    anonKey: 'YOUR_SUPABASE_ANON_KEY_HERE', 
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LabState()),
      ],
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

// --- STATE MANAGEMENT (The Brain) ---
class LabState extends ChangeNotifier {
  final _supabase = Supabase.instance.client;
  
  List<Tool> tools = [];
  List<Student> students = [];
  List<LabGroup> groups = [
    LabGroup(name: "Bench 1"),
    LabGroup(name: "Bench 2"),
    LabGroup(name: "Bench 3"),
    LabGroup(name: "Bench 4"),
  ];
  List<TransactionLog> activeLoans = [];
  List<Map<String, dynamic>> pendingRequests = [];

  Student? selectedStudent;
  LabGroup? selectedGroup;
  List<Tool> selectedTools = [];

  LabState() {
    _init();
  }

  void _init() async {
    await refresh();
    
    // Auto-seed Supabase if empty (For KIST Demo)
    if (tools.isEmpty) {
      await _supabase.from('tools').insert([
        {'uuid': '1', 'name': 'Fluke Multimeter', 'category': 'Electrical', 'is_available': true},
        {'uuid': '2', 'name': 'Screwdriver Set', 'category': 'Hand', 'is_available': true},
        {'uuid': '3', 'name': 'Soldering Station', 'category': 'Electrical', 'is_available': true},
        {'uuid': '4', 'name': 'Wire Stripper', 'category': 'Hand', 'is_available': true},
      ]);
      await _supabase.from('students').insert([
        {'adm_number': 'MECH/2026/001', 'name': 'Kamau John'},
        {'adm_number': 'MECH/2026/002', 'name': 'Wanjiku Grace'},
        {'adm_number': 'MECH/2026/003', 'name': 'Otieno Brian'},
      ]);
      await refresh();
    }

    listenToLiveQueue();
  }

  void listenToLiveQueue() {
    _supabase
        .from('tool_requests')
        .stream(primaryKey: ['id'])
        .eq('status', 'PENDING')
        .order('created_at', ascending: true)
        .listen((data) {
      pendingRequests = data;
      notifyListeners();
    });
  }

  Future<void> refresh() async {
    try {
      final toolsData = await _supabase.from('tools').select().order('name');
      tools = toolsData.map((t) => Tool(
        id: t['id'].toString(),
        name: t['name'],
        category: t['category'] ?? 'General',
        isAvailable: t['is_available'] ?? true,
      )).toList();

      final studentsData = await _supabase.from('students').select().order('name');
      students = studentsData.map((s) => Student(
        admNumber: s['adm_number'],
        name: s['name'],
      )).toList();

      final loansData = await _supabase.from('transaction_logs')
          .select()
          .eq('is_returned', false)
          .order('time_borrowed', ascending: false);
          
      activeLoans = loansData.map((l) => TransactionLog(
        id: l['id'],
        toolName: l['tool_name'],
        issuedTo: l['issued_to'] ?? l['student_name'] ?? 'Unknown',
        isGroupIssue: l['is_group_issue'] ?? false,
        timeBorrowed: DateTime.parse(l['time_borrowed']),
      )).toList();

      notifyListeners();
    } catch (e) {
      debugPrint("Error fetching data: $e");
    }
  }

  void selectStudent(Student s) {
    selectedStudent = s;
    selectedGroup = null; 
    notifyListeners();
  }

  void selectGroup(LabGroup g) {
    selectedGroup = g;
    selectedStudent = null; 
    notifyListeners();
  }

  void toggleToolSelection(Tool tool) {
    if (selectedTools.contains(tool)) {
      selectedTools.remove(tool);
    } else {
      selectedTools.add(tool);
    }
    notifyListeners();
  }

  Future<void> issueTools() async {
    if ((selectedStudent == null && selectedGroup == null) || selectedTools.isEmpty) return;

    final issuedToName = selectedStudent?.name ?? selectedGroup?.name ?? 'Unknown';
    final isGroup = selectedGroup != null;

    for (var tool in selectedTools) {
      tool.isAvailable = false; 
      
      await _supabase.from('transaction_logs').insert({
        'tool_name': tool.name,
        'issued_to': issuedToName,
        'is_group_issue': isGroup,
        'time_borrowed': DateTime.now().toIso8601String(),
        'is_returned': false,
        'status': 'GOOD'
      });
      
      await _supabase.from('tools').update({'is_available': false}).eq('id', tool.id);
    }

    selectedStudent = null;
    selectedGroup = null;
    selectedTools = [];
    await refresh();
  }

  Future<void> approveQRRequest(Map<String, dynamic> request) async {
    await _supabase.from('tool_requests').update({'status': 'ISSUED'}).eq('id', request['id']);
    
    final List requestedTools = request['tools_requested'] ?? [];
    for (var reqTool in requestedTools) {
      final toolName = reqTool['tool'];
      final tool = tools.firstWhere((t) => t.name == toolName && t.isAvailable, orElse: () => Tool(id: '', name: '', category: ''));
      
      if (tool.id.isNotEmpty) {
        await _supabase.from('transaction_logs').insert({
          'tool_name': tool.name,
          'issued_to': request['student_name'] + " (QR)",
          'is_group_issue': false,
          'time_borrowed': DateTime.now().toIso8601String(),
          'is_returned': false,
          'status': 'GOOD'
        });
        await _supabase.from('tools').update({'is_available': false}).eq('id', tool.id);
      }
    }
    await refresh();
  }

  Future<void> returnItem(TransactionLog log) async {
    await _supabase.from('transaction_logs')
        .update({'is_returned': true, 'time_returned': DateTime.now().toIso8601String()})
        .eq('id', log.id);
        
    await _supabase.from('tools').update({'is_available': true}).eq('name', log.toolName);
    await refresh();
  }
}

// --- UI DASHBOARD ---
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

    if (isDesktop) {
      return Scaffold(
        appBar: _buildAppBar(context, isDesktop),
        body: const DesktopLayout(),
      );
    }

    return Scaffold(
      appBar: _buildAppBar(context, isDesktop),
      body: TabBarView(
        controller: _tabController,
        children: const [
          SelectionPanel(), 
          ToolGridPanel(),
          ActionPanel(),
        ],
      ),
      bottomNavigationBar: Container(
        color: const Color(0xFF003366),
        child: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(icon: Icon(Icons.people), text: "Select"),
            Tab(icon: Icon(Icons.build), text: "Tools"),
            Tab(icon: Icon(Icons.shopping_cart), text: "Cart"),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, bool isDesktop) {
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(isDesktop ? "Kiambu Institute of Science and Technology" : "KIST Inventory",
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
          if (isDesktop)
            const Text("Mechatronics Department - Inventory System",
                style: TextStyle(fontSize: 12, color: Colors.white70)),
        ],
      ),
      backgroundColor: const Color(0xFF003366),
      actions: [
        if (isDesktop)
          Padding(
            padding: const EdgeInsets.only(right: 20.0),
            child: Chip(
              label: Text("Cloud Sync Active", style: TextStyle(color: Colors.green[800], fontWeight: FontWeight.bold)),
              backgroundColor: Colors.green[50],
              avatar: const Icon(Icons.wifi, color: Colors.green, size: 18),
            ),
          )
      ],
    );
  }
}

class DesktopLayout extends StatelessWidget {
  const DesktopLayout({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(flex: 3, child: SelectionPanel()), 
        VerticalDivider(width: 1),
        Expanded(flex: 5, child: ToolGridPanel()),
        VerticalDivider(width: 1),
        Expanded(flex: 3, child: ActionPanel()),
      ],
    );
  }
}

class SelectionPanel extends StatelessWidget {
  const SelectionPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    
    return DefaultTabController(
      length: 3,
      child: Container(
        color: Colors.white,
        child: Column(
          children: [
            Container(
              color: const Color(0xFF003366),
              child: const TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white54,
                indicatorColor: Colors.orange,
                tabs: [
                  Tab(text: "LIVE QR"),
                  Tab(text: "Students"),
                  Tab(text: "Groups"),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  state.pendingRequests.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.qr_code_scanner, size: 50, color: Colors.grey[300]),
                              const SizedBox(height: 10),
                              Text("Waiting for students...", style: TextStyle(color: Colors.grey[500])),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(8),
                          itemCount: state.pendingRequests.length,
                          itemBuilder: (context, index) {
                            final req = state.pendingRequests[index];
                            final List toolsList = req['tools_requested'] ?? [];
                            return Card(
                              color: Colors.orange[50],
                              child: ListTile(
                                leading: const Icon(Icons.notifications_active, color: Colors.orange),
                                title: Text(req['student_name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                                subtitle: Text("Class: ${req['class_name']}\nTools: ${toolsList.length}"),
                                trailing: ElevatedButton(
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                                  onPressed: () => state.approveQRRequest(req),
                                  child: const Text("APPROVE"),
                                ),
                              ),
                            );
                          },
                        ),

                  ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: state.students.length,
                    itemBuilder: (context, index) {
                      final student = state.students[index];
                      final isSelected = state.selectedStudent?.admNumber == student.admNumber;
                      return ListTile(
                        title: Text(student.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text("${student.admNumber} • ${student.groupName ?? ''}"),
                        selected: isSelected,
                        tileColor: isSelected ? const Color(0xFFE3F2FD) : null,
                        onTap: () => state.selectStudent(student),
                        leading: CircleAvatar(
                          backgroundColor: isSelected ? const Color(0xFF003366) : Colors.grey[200],
                          foregroundColor: isSelected ? Colors.white : Colors.black,
                          child: Text(student.name[0]),
                        ),
                      );
                    },
                  ),

                  ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: state.groups.length,
                    itemBuilder: (context, index) {
                      final group = state.groups[index];
                      final isSelected = state.selectedGroup?.name == group.name;
                      return ListTile(
                        title: Text(group.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        leading: Icon(Icons.workspaces, color: isSelected ? const Color(0xFF003366) : Colors.grey),
                        selected: isSelected,
                        tileColor: isSelected ? const Color(0xFFE3F2FD) : null,
                        onTap: () => state.selectGroup(group),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ToolGridPanel extends StatelessWidget {
  const ToolGridPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    return Container(
      color: const Color(0xFFFAFAFA),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("2. Select Tools to Issue", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 10),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                childAspectRatio: 1.2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: state.tools.length,
              itemBuilder: (context, index) {
                final tool = state.tools[index];
                final isSelected = state.selectedTools.contains(tool);
                if (!tool.isAvailable) {
                  return Container(
                    decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(8)),
                    child: Center(child: Text("${tool.name}\n(OUT)", textAlign: TextAlign.center, style: const TextStyle(color: Colors.red))),
                  );
                }
                return InkWell(
                  onTap: () => state.toggleToolSelection(tool),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFF003366) : Colors.white,
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.build_circle_outlined, size: 30, color: isSelected ? Colors.white : const Color(0xFF003366)),
                        const SizedBox(height: 5),
                        Text(tool.name, textAlign: TextAlign.center, 
                             style: TextStyle(color: isSelected ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ActionPanel extends StatelessWidget {
  const ActionPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    
    final receiverName = state.selectedStudent?.name ?? state.selectedGroup?.name;
    final isGroup = state.selectedGroup != null;

    return Column(
      children: [
        Expanded(
          flex: 2,
          child: Container(
            color: Colors.blue[50],
            padding: const EdgeInsets.all(16),
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Confirm Manual Issue", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF003366))),
                const Divider(),
                if (receiverName != null) ...[
                  Text(isGroup ? "Group:" : "Student:", style: TextStyle(color: Colors.grey[700], fontSize: 12)),
                  Text(receiverName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ] else 
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Text("Select a student or group first...", style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey)),
                  ),
                const SizedBox(height: 10),
                Expanded(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 5,
                      children: state.selectedTools.map((t) => Chip(
                        label: Text(t.name, style: const TextStyle(fontSize: 11)),
                        onDeleted: () => state.toggleToolSelection(t),
                        backgroundColor: Colors.white,
                      )).toList(),
                    ),
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), foregroundColor: Colors.white),
                    onPressed: (receiverName != null && state.selectedTools.isNotEmpty) ? () => state.issueTools() : null,
                    icon: const Icon(Icons.check_circle),
                    label: const Text("ISSUE TOOLS"),
                  ),
                )
              ],
            ),
          ),
        ),
        Expanded(
          flex: 3,
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Active Returns", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView.separated(
                    itemCount: state.activeLoans.length,
                    separatorBuilder: (_,__) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final loan = state.activeLoans[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.access_time_filled, color: Colors.orange),
                        title: Text(loan.issuedTo + (loan.isGroupIssue ? " (Group)" : ""), 
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        subtitle: Text(loan.toolName, style: const TextStyle(fontSize: 12)),
                        trailing: TextButton(
                          onPressed: () => state.returnItem(loan),
                          style: TextButton.styleFrom(foregroundColor: Colors.green),
                          child: const Text("RETURN"),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}