import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'data/schemas.dart';
import 'services/supabase_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize Supabase (Cloud)
  await Supabase.initialize(
    url: 'YOUR_SUPABASE_URL_HERE', // REMEMBER TO PASTE YOUR URL
    anonKey: 'YOUR_SUPABASE_ANON_KEY_HERE', // REMEMBER TO PASTE YOUR KEY
  );

  // 2. Initialize Isar (Local)
  final dir = await getApplicationDocumentsDirectory();
  final isar = await Isar.open(
    [ToolSchema, StudentSchema, LabGroupSchema, TransactionLogSchema],
    directory: dir.path,
  );

  runApp(
    MultiProvider(
      providers: [
        Provider<Isar>.value(value: isar),
        Provider<SupabaseService>(create: (_) => SupabaseService()),
        ChangeNotifierProvider(create: (_) => LabState(isar, SupabaseService())),
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
  final Isar isar;
  final SupabaseService supabaseService;
  
  List<Tool> tools = [];
  List<Student> students = [];
  List<LabGroup> groups = [];
  List<TransactionLog> activeLoans = [];
  
  // LIVE QUEUE
  List<Map<String, dynamic>> pendingRequests = [];

  // The "Cart"
  Student? selectedStudent;
  LabGroup? selectedGroup;
  List<Tool> selectedTools = [];

  LabState(this.isar, this.supabaseService) {
    _init();
  }

  void _init() async {
    await refresh();
    
    // IF EMPTY: Add dummy data for KIST Demo
    if (tools.isEmpty) {
      await isar.writeTxn(() async {
        // Dummy Groups
        await isar.labGroups.putAll([
          LabGroup(name: "Bench 1"),
          LabGroup(name: "Bench 2"),
          LabGroup(name: "Bench 3"),
        ]);
        // Dummy Students
        await isar.students.putAll([
          Student(admNumber: "MECH/2026/001", name: "Kamau John", groupName: "Bench 1"),
          Student(admNumber: "MECH/2026/002", name: "Wanjiku Grace", groupName: "Bench 1"),
          Student(admNumber: "MECH/2026/003", name: "Otieno Brian", groupName: "Bench 2"),
        ]);
        // Dummy Tools
        await isar.tools.putAll([
          Tool(uuid: const Uuid().v4(), name: "Fluke Multimeter", category: "Electrical"),
          Tool(uuid: const Uuid().v4(), name: "Screwdriver Set", category: "Hand"),
          Tool(uuid: const Uuid().v4(), name: "Soldering Station", category: "Electrical"),
          Tool(uuid: const Uuid().v4(), name: "Wire Stripper", category: "Hand"),
        ]);
      });
      await refresh();
    }

    // START LISTENING TO QR CODE REQUESTS LIVE
    listenToLiveQueue();
  }

  void listenToLiveQueue() {
    supabaseService.liveToolRequests.listen((data) {
      pendingRequests = data;
      notifyListeners();
    });
  }

  Future<void> refresh() async {
    tools = await isar.tools.where().findAll();
    students = await isar.students.where().findAll();
    groups = await isar.labGroups.where().findAll();
    activeLoans = await isar.transactionLogs.filter().isReturnedEqualTo(false).sortByTimeBorrowedDesc().findAll();
    notifyListeners();
  }

  void selectStudent(Student s) {
    selectedStudent = s;
    selectedGroup = null; // Clear group if student is selected
    notifyListeners();
  }

  void selectGroup(LabGroup g) {
    selectedGroup = g;
    selectedStudent = null; // Clear student if group is selected
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

  // STANDARD ISSUE (Manual)
  Future<void> issueTools() async {
    if ((selectedStudent == null && selectedGroup == null) || selectedTools.isEmpty) return;

    final issuedToName = selectedStudent?.name ?? selectedGroup?.name ?? 'Unknown';
    final isGroup = selectedGroup != null;

    await isar.writeTxn(() async {
      for (var tool in selectedTools) {
        tool.isAvailable = false;
        await isar.tools.put(tool);
        
        final log = TransactionLog(
          toolName: tool.name,
          issuedTo: issuedToName,
          isGroupIssue: isGroup,
          timeBorrowed: DateTime.now(),
        );
        await isar.transactionLogs.put(log);
        
        // Tell Cloud (Silent background sync)
        supabaseService.logTransaction(log);
      }
    });

    selectedStudent = null;
    selectedGroup = null;
    selectedTools = [];
    await refresh();
  }

  // APPROVE LIVE QR REQUEST
  Future<void> approveQRRequest(Map<String, dynamic> request) async {
    // 1. Mark as Issued in Cloud instantly
    await supabaseService.approveRequest(request['id']);
    
    // 2. We will auto-issue the tools locally if we have them
    final List requestedTools = request['tools_requested'] ?? [];
    
    await isar.writeTxn(() async {
      for (var reqTool in requestedTools) {
        final toolName = reqTool['tool'];
        
        // Find an available tool matching the requested name
        final localTool = await isar.tools.filter().nameEqualTo(toolName).isAvailableEqualTo(true).findFirst();
        
        if (localTool != null) {
          localTool.isAvailable = false;
          await isar.tools.put(localTool);
          
          await isar.transactionLogs.put(TransactionLog(
            toolName: localTool.name,
            issuedTo: request['student_name'] + " (QR)",
            isGroupIssue: false,
            timeBorrowed: DateTime.now(),
          ));
        }
      }
    });
    
    await refresh();
  }

  Future<void> returnItem(TransactionLog log) async {
    await isar.writeTxn(() async {
      log.isReturned = true;
      log.timeReturned = DateTime.now();
      await isar.transactionLogs.put(log);

      final tool = await isar.tools.filter().nameEqualTo(log.toolName).findFirst();
      if (tool != null) {
        tool.isAvailable = true;
        await isar.tools.put(tool);
      }
    });
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
          SelectionPanel(), // Has Live Queue, Students, Groups
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
        Expanded(flex: 3, child: SelectionPanel()), // Expanded to fit tabs
        VerticalDivider(width: 1),
        Expanded(flex: 5, child: ToolGridPanel()),
        VerticalDivider(width: 1),
        Expanded(flex: 3, child: ActionPanel()),
      ],
    );
  }
}

// PANEL 1: SELECTION (Live Queue, Students, Groups)
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
                  // TAB 1: LIVE QR QUEUE
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

                  // TAB 2: STUDENTS
                  ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: state.students.length,
                    itemBuilder: (context, index) {
                      final student = state.students[index];
                      final isSelected = state.selectedStudent?.id == student.id;
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

                  // TAB 3: GROUPS
                  ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: state.groups.length,
                    itemBuilder: (context, index) {
                      final group = state.groups[index];
                      final isSelected = state.selectedGroup?.id == group.id;
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

// PANEL 2: TOOLS (Unchanged logic, just UI tweaks)
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

// PANEL 3: ACTIONS
class ActionPanel extends StatelessWidget {
  const ActionPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    
    // Determine who is receiving the tools
    final receiverName = state.selectedStudent?.name ?? state.selectedGroup?.name;
    final isGroup = state.selectedGroup != null;

    return Column(
      children: [
        // CART AREA
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
        // ACTIVE LOANS LIST
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