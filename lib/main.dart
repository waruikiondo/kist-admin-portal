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
  
  // Connect to Supabase
  await Supabase.initialize(
    url: 'YOUR_SUPABASE_URL_HERE', 
    anonKey: 'YOUR_SUPABASE_ANON_KEY_HERE'
  );
  
  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => LabState())],
      child: const KinapLabApp(),
    ),
  );
}

class KinapLabApp extends StatelessWidget {
  const KinapLabApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'KINAP Mechatronics Lab',
      theme: ThemeData(
        useMaterial3: true,
        textTheme: GoogleFonts.outfitTextTheme(),
        // BRANDING UPDATED TO KINAP RED (#D32F2F)
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFD32F2F)),
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
  List<LabGroup> groups = [LabGroup(name: "DIM2509B"), LabGroup(name: "DIM2509A"), LabGroup(name: "DIM2505B"), LabGroup(name: "DIM2505A"), LabGroup(name: "DIM2409B"), LabGroup(name: "DIM2409A"), LabGroup(name: "DIM2405"), LabGroup(name: "DIM2309")];
  List<TransactionLog> activeLoans = [];
  List<Map<String, dynamic>> pendingRequests = [];

  Student? selectedStudent;
  LabGroup? selectedGroup;
  List<Tool> selectedTools = [];
  
  String studentSearchQuery = '';

  LabState() { _init(); }

  void _init() async {
    await refresh();
    listenToLiveQueue();
  }

  void listenToLiveQueue() {
    _supabase.from('tool_requests').stream(primaryKey: ['id']).eq('status', 'PENDING').order('created_at', ascending: true).listen((data) {
      pendingRequests = data;
      notifyListeners();
    });
  }

  Future<void> refresh() async {
    try {
      final toolsData = await _supabase.from('tools').select().order('name');
      tools = toolsData.map((t) => Tool(id: t['id'].toString(), name: t['name'], category: t['category'] ?? 'General', isAvailable: t['is_available'] ?? true)).toList();

      final studentsData = await _supabase.from('students').select().order('name');
      students = studentsData.map((s) => Student(admNumber: s['adm_number'], name: s['name'], groupName: s['group_name'])).toList();

      final loansData = await _supabase.from('transaction_logs').select().eq('is_returned', false).order('time_borrowed', ascending: false);
      activeLoans = loansData.map((l) => TransactionLog(id: l['id'], toolName: l['tool_name'], issuedTo: l['issued_to'] ?? 'Unknown', isGroupIssue: l['is_group_issue'] ?? false, timeBorrowed: DateTime.parse(l['time_borrowed']))).toList();

      notifyListeners();
    } catch (e) { debugPrint("Error: $e"); }
  }

  List<Student> get filteredStudents {
    if (studentSearchQuery.isEmpty) return students;
    return students.where((s) {
      final query = studentSearchQuery.toLowerCase();
      return s.admNumber.toLowerCase().contains(query) || 
             s.name.toLowerCase().contains(query);
    }).toList();
  }

  void setStudentSearchQuery(String query) {
    studentSearchQuery = query;
    notifyListeners();
  }

  void selectStudent(Student s) { selectedStudent = s; selectedGroup = null; notifyListeners(); }
  void selectGroup(LabGroup g) { selectedGroup = g; selectedStudent = null; notifyListeners(); }
  void toggleToolSelection(Tool tool) { selectedTools.contains(tool) ? selectedTools.remove(tool) : selectedTools.add(tool); notifyListeners(); }

  // NEW: Added phone parameter for manual entry
  Future<void> issueTools({String phone = ''}) async {
    if ((selectedStudent == null && selectedGroup == null) || selectedTools.isEmpty) return;
    
    String issuedToName = selectedStudent?.name ?? selectedGroup?.name ?? 'Unknown';
    final isGroup = selectedGroup != null;

    // Append the phone number to the log if provided
    if (!isGroup && phone.isNotEmpty) {
      issuedToName += ' ($phone)';
    }

    for (var tool in selectedTools) {
      tool.isAvailable = false; 
      await _supabase.from('transaction_logs').insert({'tool_name': tool.name, 'issued_to': issuedToName, 'is_group_issue': isGroup, 'time_borrowed': DateTime.now().toIso8601String(), 'is_returned': false, 'status': 'GOOD'});
      await _supabase.from('tools').update({'is_available': false}).eq('id', tool.id);
    }
    selectedStudent = null; selectedGroup = null; selectedTools = [];
    await refresh();
  }

  Future<void> approveQRRequest(Map<String, dynamic> request) async {
    await _supabase.from('tool_requests').update({'status': 'ISSUED'}).eq('id', request['id']);
    final List requestedTools = request['tools_requested'] ?? [];
    for (var reqTool in requestedTools) {
      final toolName = reqTool['tool'];
      final tool = tools.firstWhere((t) => t.name == toolName && t.isAvailable, orElse: () => Tool(id: '', name: '', category: ''));
      if (tool.id.isNotEmpty) {
        await _supabase.from('transaction_logs').insert({'tool_name': tool.name, 'issued_to': request['student_name'] + " (QR)", 'is_group_issue': false, 'time_borrowed': DateTime.now().toIso8601String(), 'is_returned': false, 'status': 'GOOD'});
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
    if (isDesktop) return Scaffold(appBar: _buildAppBar(context, isDesktop), body: const DesktopLayout());
    return Scaffold(
      appBar: _buildAppBar(context, isDesktop),
      body: TabBarView(controller: _tabController, children: const [SelectionPanel(), ToolGridPanel(), ActionPanel()]),
      bottomNavigationBar: Container(
        color: const Color(0xFFD32F2F), // Red Navigation
        child: TabBar(
          controller: _tabController, indicatorColor: Colors.white, labelColor: Colors.white, unselectedLabelColor: Colors.white60,
          tabs: const [Tab(icon: Icon(Icons.people), text: "Select"), Tab(icon: Icon(Icons.build), text: "Tools"), Tab(icon: Icon(Icons.shopping_cart), text: "Cart")],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, bool isDesktop) {
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(isDesktop ? "THE KIAMBU NATIONAL POLYTECHNIC" : "KINAP Inventory", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white, letterSpacing: 1.0)),
          if (isDesktop) const Text("Mechanical, Mechatronics & Automotive Engineering Department", style: TextStyle(fontSize: 12, color: Colors.white70)),
        ],
      ),
      backgroundColor: const Color(0xFFD32F2F), // KINAP RED
      actions: [
        if (isDesktop)
          Padding(
            padding: const EdgeInsets.only(right: 20.0),
            child: Chip(label: Text("Cloud Sync Active", style: TextStyle(color: Colors.green[800], fontWeight: FontWeight.bold)), backgroundColor: Colors.green[50], avatar: const Icon(Icons.wifi, color: Colors.green, size: 18)),
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
              color: const Color(0xFF1A1A1A), // Black tab header to complement the Red
              child: const TabBar(
                labelColor: Colors.white, unselectedLabelColor: Colors.white54, indicatorColor: Color(0xFFD32F2F), // Red indicator
                tabs: [Tab(text: "LIVE QR"), Tab(text: "Students"), Tab(text: "Groups")],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  // TAB 1: LIVE QR QUEUE
                  state.pendingRequests.isEmpty
                      ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.qr_code_scanner, size: 50, color: Colors.grey[300]), const SizedBox(height: 10), Text("Waiting for students...", style: TextStyle(color: Colors.grey[500]))]))
                      : ListView.builder(
                          padding: const EdgeInsets.all(8),
                          itemCount: state.pendingRequests.length,
                          itemBuilder: (context, index) {
                            final req = state.pendingRequests[index];
                            final List toolsList = req['tools_requested'] ?? [];
                            return Card(
                              color: Colors.red.shade50,
                              child: ListTile(
                                leading: const Icon(Icons.notifications_active, color: Color(0xFFD32F2F)),
                                title: Text(req['student_name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                                subtitle: Text("Class: ${req['class_name']}\nTools: ${toolsList.length}"),
                                trailing: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white), onPressed: () => state.approveQRRequest(req), child: const Text("APPROVE")),
                              ),
                            );
                          },
                        ),

                  // TAB 2: STUDENTS
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: "Search Admission No. or Name...",
                            prefixIcon: const Icon(Icons.search, color: Color(0xFFD32F2F)),
                            filled: true,
                            fillColor: Colors.grey.shade100,
                            contentPadding: const EdgeInsets.symmetric(vertical: 0),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                          ),
                          onChanged: (value) => state.setStudentSearchQuery(value),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          itemCount: state.filteredStudents.length,
                          itemBuilder: (context, index) {
                            final student = state.filteredStudents[index];
                            final isSelected = state.selectedStudent?.admNumber == student.admNumber;
                            return Card(
                              elevation: 0,
                              color: isSelected ? Colors.red.shade50 : Colors.transparent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: isSelected ? const BorderSide(color: Color(0xFFD32F2F), width: 1) : BorderSide(color: Colors.grey.shade200),
                              ),
                              child: ListTile(
                                title: Text(student.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                                subtitle: Text("${student.admNumber} • ${student.groupName ?? ''}"),
                                selected: isSelected,
                                onTap: () => state.selectStudent(student),
                                leading: CircleAvatar(
                                  backgroundColor: isSelected ? const Color(0xFFD32F2F) : Colors.grey[200],
                                  foregroundColor: isSelected ? Colors.white : Colors.black,
                                  child: Text(student.name[0]),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),

                  // TAB 3: GROUPS
                  ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: state.groups.length,
                    itemBuilder: (context, index) {
                      final group = state.groups[index];
                      final isSelected = state.selectedGroup?.name == group.name;
                      return ListTile(
                        title: Text(group.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        leading: Icon(Icons.workspaces, color: isSelected ? const Color(0xFFD32F2F) : Colors.grey),
                        selected: isSelected,
                        tileColor: isSelected ? Colors.red.shade50 : null,
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
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, childAspectRatio: 1.2, crossAxisSpacing: 10, mainAxisSpacing: 10),
              itemCount: state.tools.length,
              itemBuilder: (context, index) {
                final tool = state.tools[index];
                final isSelected = state.selectedTools.contains(tool);
                if (!tool.isAvailable) {
                  return Container(decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(8)), child: Center(child: Text("${tool.name}\n(OUT)", textAlign: TextAlign.center, style: const TextStyle(color: Colors.red))));
                }
                return InkWell(
                  onTap: () => state.toggleToolSelection(tool),
                  child: Container(
                    decoration: BoxDecoration(color: isSelected ? const Color(0xFF1A1A1A) : Colors.white, border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.build_circle_outlined, size: 30, color: isSelected ? Colors.white : const Color(0xFF1A1A1A)), const SizedBox(height: 5), Text(tool.name, textAlign: TextAlign.center, style: TextStyle(color: isSelected ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 12))]),
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

// --- UPDATED ACTION PANEL (CART) ---
class ActionPanel extends StatefulWidget {
  const ActionPanel({super.key});
  @override
  State<ActionPanel> createState() => _ActionPanelState();
}

class _ActionPanelState extends State<ActionPanel> {
  final _phoneController = TextEditingController();

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    final isGroup = state.selectedGroup != null;

    return Column(
      children: [
        // CART AREA
        Expanded(
          flex: 2,
          child: Container(
            color: Colors.red.shade50,
            padding: const EdgeInsets.all(16),
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Confirm Manual Issue", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFD32F2F))),
                const Divider(),
                
                // AUTO-FILL DISPLAY AREA
                if (state.selectedStudent != null || state.selectedGroup != null) ...[
                  Text(isGroup ? "Group:" : "Student Details:", style: TextStyle(color: Colors.grey[700], fontSize: 12)),
                  Text(state.selectedStudent?.name ?? state.selectedGroup!.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  
                  if (!isGroup) ...[
                    Text("ADM: ${state.selectedStudent!.admNumber}  |  Class: ${state.selectedStudent!.groupName ?? 'N/A'}", style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                    const SizedBox(height: 10),
                    // NEW: PHONE NUMBER MANUAL ENTRY
                    TextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: 'Phone Number (Optional)',
                        prefixIcon: const Icon(Icons.phone, size: 18),
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      ),
                    ),
                  ],
                ] else 
                  const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text("Search for a student to auto-fill...", style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey))),
                
                const SizedBox(height: 10),
                Expanded(child: SingleChildScrollView(child: Wrap(spacing: 5, children: state.selectedTools.map((t) => Chip(label: Text(t.name, style: const TextStyle(fontSize: 11)), onDeleted: () => state.toggleToolSelection(t), backgroundColor: Colors.white)).toList()))),
                
                SizedBox(
                  width: double.infinity, height: 50,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), foregroundColor: Colors.white),
                    onPressed: ((state.selectedStudent != null || state.selectedGroup != null) && state.selectedTools.isNotEmpty) 
                      ? () {
                          state.issueTools(phone: _phoneController.text.trim());
                          _phoneController.clear(); // Clear the phone box after issue
                        } 
                      : null,
                    icon: const Icon(Icons.check_circle), label: const Text("ISSUE TOOLS"),
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
                        title: Text(loan.issuedTo + (loan.isGroupIssue ? " (Group)" : ""), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        subtitle: Text(loan.toolName, style: const TextStyle(fontSize: 12)),
                        trailing: TextButton(onPressed: () => state.returnItem(loan), style: TextButton.styleFrom(foregroundColor: Colors.green), child: const Text("RETURN")),
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