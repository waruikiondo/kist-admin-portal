import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sync_pdf; 
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/schemas.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AppBootstrapper());
}

// --- NON-BLOCKING BOOTSTRAPPER ---
class AppBootstrapper extends StatefulWidget {
  const AppBootstrapper({super.key});

  @override
  State<AppBootstrapper> createState() => _AppBootstrapperState();
}

class _AppBootstrapperState extends State<AppBootstrapper> {
  Isar? localIsar;
  bool isInitializing = true;
  String loadingStatus = "Waking up system...";

  @override
  void initState() {
    super.initState();
    _setupDatabases();
  }

  Future<void> _setupDatabases() async {
    try {
      setState(() => loadingStatus = "Connecting to cloud...");
      await Supabase.initialize(
        url: 'https://htvyekhsxzctvlltqtsq.supabase.co', 
        anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh0dnlla2hzeHpjdHZsbHRxdHNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzEwMDA1NjMsImV4cCI6MjA4NjU3NjU2M30.F8DUOG6q9ynw1IbIkn1Q1GJfICL_XvJKb9V-AlPCuEw'
      );

      setState(() => loadingStatus = "Setting up local storage...");
      if (!kIsWeb) {
        final dir = await getApplicationDocumentsDirectory();
        localIsar = await Isar.open(
          [ToolSchema, StudentSchema, LabGroupSchema, TransactionLogSchema],
          directory: dir.path,
        );
      }
    } catch (e) {
      debugPrint("Initialization error: $e");
    } finally {
      if (mounted) {
        setState(() {
          isInitializing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isInitializing) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFFD32F2F),
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 20),
                Text(
                  loadingStatus,
                  style: GoogleFonts.outfit(color: Colors.white, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => LabState(localIsar))],
      child: const KinapLabApp(),
    );
  }
}

class KinapLabApp extends StatelessWidget {
  const KinapLabApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'KINAP Mechatronics POS',
      theme: ThemeData(
        useMaterial3: true,
        textTheme: GoogleFonts.outfitTextTheme(),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFD32F2F)),
        scaffoldBackgroundColor: const Color(0xFFF0F2F5),
      ),
      home: const PosDashboard(),
    );
  }
}

// --- STATE MANAGEMENT ---
class LabState extends ChangeNotifier {
  final Isar? isar; 
  bool get isWeb => isar == null; 
  
  List<Student> allStudents = [];
  List<Student> filteredStudents = [];
  List<TransactionLog> activeLoans = [];
  
  Student? selectedStudent;
  List<String> cartItems = []; 
  String searchQuery = '';
  String? selectedClassFilter; 
  
  bool isSyncing = false; 
  bool isIssuing = false; 
  
  // NEW: Global tracker for Mobile Navigation
  int mobileTabIndex = 0;

  LabState(this.isar) {
    _init();
  }

  Future<void> _init() async {
    await refreshData();
  }

  // --- MOBILE NAVIGATION LOGIC ---
  void setMobileTab(int index) {
    mobileTabIndex = index;
    notifyListeners();
  }

  // --- BLACKLIST LOGIC ---
  bool isStudentBlacklisted(Student student) {
    return activeLoans.any((loan) => loan.issuedTo.contains(student.admNumber));
  }

  List<String> getUnreturnedItemsFor(Student student) {
    return activeLoans
        .where((loan) => loan.issuedTo.contains(student.admNumber))
        .map((loan) => loan.toolName)
        .toList();
  }
  // -----------------------

  Future<void> refreshData() async {
    if (!isWeb) {
      allStudents = await isar!.students.where().findAll();
      activeLoans = await isar!.transactionLogs.filter().isReturnedEqualTo(false).sortByTimeBorrowedDesc().findAll();
    } else {
      try {
        final supabase = Supabase.instance.client;
        
        final studentRes = await supabase.from('students').select();
        allStudents = studentRes.map((s) => Student(
          admNumber: s['adm_number'], 
          name: s['name'], 
          groupName: s['group_name']
        )).toList();

        final logRes = await supabase.from('transaction_logs').select().eq('is_returned', false).order('time_borrowed', ascending: false);
        activeLoans = logRes.map((l) {
          final log = TransactionLog(
            toolName: l['tool_name'],
            issuedTo: l['issued_to'],
            timeBorrowed: DateTime.parse(l['time_borrowed']),
            isGroupIssue: l['is_group_issue'] ?? false,
            isReturned: false,
            isSynced: true,
          );
          log.id = l['id'] ?? DateTime.now().millisecondsSinceEpoch;
          return log;
        }).toList();
      } catch (e) {
        debugPrint("Web Fetch Error: $e");
      }
    }
    _applyFilter();
    notifyListeners();
  }

  List<String> get uploadedClasses {
    final classes = allStudents.map((s) => s.groupName ?? '').where((g) => g.isNotEmpty).toSet().toList();
    classes.sort();
    return classes;
  }

  void searchStudent(String query) {
    searchQuery = query.trim().toLowerCase();
    _applyFilter();
  }

  void toggleClassFilter(String className) {
    if (selectedClassFilter == className) {
      selectedClassFilter = null; 
    } else {
      selectedClassFilter = className; 
    }
    _applyFilter();
  }

  void _applyFilter() {
    var tempList = allStudents;
    if (selectedClassFilter != null) {
      tempList = tempList.where((s) => s.groupName == selectedClassFilter).toList();
    }
    if (searchQuery.isNotEmpty) {
      final tokens = searchQuery.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      tempList = tempList.where((s) {
        final searchableString = '${s.admNumber} ${s.name}'.replaceAll('/', '').toLowerCase();
        return tokens.every((token) => searchableString.contains(token));
      }).toList();
    }
    filteredStudents = tempList.take(50).toList(); 
    notifyListeners();
  }

  void selectStudent(Student s) {
    selectedStudent = s;
    searchQuery = '';
    mobileTabIndex = 1; // Auto-navigate to Tools tab on Mobile
    notifyListeners();
  }

  void clearSelection() {
    selectedStudent = null;
    cartItems.clear();
    mobileTabIndex = 0; // Auto-navigate to Search tab on Mobile
    notifyListeners();
  }

  void addToCart(String item) {
    if (item.trim().isNotEmpty) {
      cartItems.add(item.trim());
      mobileTabIndex = 2; // Auto-navigate to Checkout tab on Mobile
      notifyListeners();
    }
  }

  void removeFromCart(String item) {
    cartItems.remove(item);
    notifyListeners();
  }

  Future<void> issueTools(BuildContext context) async {
    if (selectedStudent == null || cartItems.isEmpty) return;
    if (isStudentBlacklisted(selectedStudent!)) return;

    isIssuing = true;
    notifyListeners();

    final now = DateTime.now();
    
    try {
      if (!isWeb) {
        await isar!.writeTxn(() async {
          for (var item in cartItems) {
            final log = TransactionLog(
              toolName: item,
              issuedTo: "${selectedStudent!.name} (${selectedStudent!.admNumber})",
              timeBorrowed: now,
              isGroupIssue: false,
              isReturned: false,
              isSynced: false,
            );
            await isar!.transactionLogs.put(log);
          }
        });
      } else {
        final supabase = Supabase.instance.client;
        for (var item in cartItems) {
          // FIX: Removed 'is_group_issue' to prevent the PostgrestException crash
          await supabase.from('transaction_logs').insert({
            'tool_name': item,
            'issued_to': "${selectedStudent!.name} (${selectedStudent!.admNumber})",
            'time_borrowed': now.toIso8601String(),
            'is_returned': false,
          });
        }
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Tools Issued Successfully! ✅"), backgroundColor: Colors.green)
        );
      }
      clearSelection(); // This clears the cart AND auto-routes back to Tab 0
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to issue tools: $e"), backgroundColor: Colors.red)
        );
      }
    } finally {
      isIssuing = false;
      await refreshData();
    }
  }

  Future<void> returnTool(BuildContext context, int logId) async {
    try {
      if (!isWeb) {
        await isar!.writeTxn(() async {
          final log = await isar!.transactionLogs.get(logId);
          if (log != null) {
            log.isReturned = true;
            log.timeReturned = DateTime.now();
            log.isSynced = false; 
            await isar!.transactionLogs.put(log);
          }
        });
      } else {
        await Supabase.instance.client.from('transaction_logs').update({
          'is_returned': true,
          'time_returned': DateTime.now().toIso8601String()
        }).eq('id', logId);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Item returned to inventory!"), backgroundColor: Colors.green)
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to return item: $e"), backgroundColor: Colors.red)
        );
      }
    } finally {
      await refreshData();
    }
  }

  Future<int> bulkImportFromPdf(String className) async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result == null || result.files.single.path == null) return -1; 

    final File file = File(result.files.single.path!);
    final sync_pdf.PdfDocument document = sync_pdf.PdfDocument(inputBytes: await file.readAsBytes());
    final String rawText = sync_pdf.PdfTextExtractor(document).extractText();
    document.dispose();

    int importedCount = 0;
    final RegExp admExp = RegExp(r'(DIM|MET5|ΜΕΤ5)\s*/\s*\d{4}\s*/\s*\d{2}', caseSensitive: false);
    final lines = rawText.split('\n');
    
    if (!isWeb) {
      await isar!.writeTxn(() async {
        for (int i = 0; i < lines.length; i++) {
          final line = lines[i];
          final match = admExp.firstMatch(line);
          if (match != null) {
            final adm = match.group(0)!.replaceAll(RegExp(r'\s+'), '').toUpperCase();
            var name = line.substring(match.end).replaceAll(RegExp(r'^[^a-zA-Z]+'), '').trim();
            if (name.isEmpty && i + 1 < lines.length) {
                final nextLine = lines[i+1];
                if (!admExp.hasMatch(nextLine)) { name = nextLine.replaceAll(RegExp(r'^[^a-zA-Z]+'), '').trim(); }
            }
            if (name.isEmpty) name = "Unknown Name";

            final existing = await isar!.students.filter().admNumberEqualTo(adm).findFirst();
            if (existing == null) {
              await isar!.students.put(Student(admNumber: adm, name: name, groupName: className));
              importedCount++;
            } else {
              existing.name = name != "Unknown Name" ? name : existing.name;
              existing.groupName = className;
              await isar!.students.put(existing);
              importedCount++;
            }
          }
        }
      });
    }
    
    selectedClassFilter = className;
    searchQuery = '';
    await refreshData();
    return importedCount;
  }

  Future<void> syncWithCloud(BuildContext context) async {
    if (isWeb) {
      await refreshData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Web Portal is Live! ☁️✅"), backgroundColor: Colors.green));
      }
      return;
    }

    if (isSyncing) return;
    isSyncing = true;
    notifyListeners();

    try {
      final supabase = Supabase.instance.client;

      final localStudents = await isar!.students.where().findAll();
      for (var student in localStudents) {
        await supabase.from('students').upsert({
          'adm_number': student.admNumber,
          'name': student.name,
          'group_name': student.groupName,
        }, onConflict: 'adm_number'); 
      }

      final cloudStudents = await supabase.from('students').select();
      await isar!.writeTxn(() async {
        for (var row in cloudStudents) {
          final adm = row['adm_number'];
          final existing = await isar!.students.filter().admNumberEqualTo(adm).findFirst();
          if (existing == null) {
            await isar!.students.put(Student(
              admNumber: adm,
              name: row['name'],
              groupName: row['group_name']
            ));
          }
        }
      });

      final unsyncedLogs = await isar!.transactionLogs.filter().isSyncedEqualTo(false).findAll();
      for (var log in unsyncedLogs) {
        // FIX: Removed 'is_group_issue' to prevent the PostgrestException crash
        await supabase.from('transaction_logs').insert({
          'tool_name': log.toolName,
          'issued_to': log.issuedTo,
          'time_borrowed': log.timeBorrowed.toIso8601String(),
          'is_returned': log.isReturned,
          'time_returned': log.timeReturned?.toIso8601String(),
        });
      }

      await isar!.writeTxn(() async {
        for (var log in unsyncedLogs) {
          log.isSynced = true;
          await isar!.transactionLogs.put(log);
        }
      });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Cloud Sync Complete! ☁️✅"), backgroundColor: Colors.green));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Sync failed. Check connection: $e"), backgroundColor: Colors.red));
      }
    } finally {
      isSyncing = false;
      await refreshData();
    }
  }
}

// --- UI DASHBOARD ---
class PosDashboard extends StatelessWidget {
  const PosDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width > 800;

    return Scaffold(
      appBar: AppBar(
        title: const Text("KINAP Lab POS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFFD32F2F),
        actions: [
          Consumer<LabState>(
            builder: (context, state, child) {
              return IconButton(
                icon: state.isSyncing 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.cloud_sync, color: Colors.white),
                tooltip: "Sync with Cloud",
                onPressed: state.isSyncing ? null : () => state.syncWithCloud(context),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.group_add, color: Colors.white),
            tooltip: "Bulk Import Class",
            onPressed: () => _showBulkImportDialog(context),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: isDesktop ? const DesktopPosLayout() : const MobilePosLayout(),
    );
  }

  void _showBulkImportDialog(BuildContext context) {
    final classCtrl = TextEditingController();
    
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Import Class from PDF"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Enter the class name, then attach the PDF file to auto-import students.", style: TextStyle(fontSize: 14)),
            const SizedBox(height: 15),
            TextField(
              controller: classCtrl,
              decoration: const InputDecoration(labelText: "Class Name (e.g., DIM2409B)", border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text("Cancel")),
          ElevatedButton.icon(
            onPressed: () async {
              if (classCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please enter a class name!")));
                return;
              }
              Navigator.pop(dialogContext); 
              
              try {
                final count = await context.read<LabState>().bulkImportFromPdf(classCtrl.text.trim().toUpperCase());
                if (count > 0 && context.mounted) {
                   ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Success: Extracted $count students!"), backgroundColor: Colors.green));
                } else if (count == 0 && context.mounted) {
                   ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No students found in that PDF."), backgroundColor: Colors.orange));
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error reading PDF: $e"), backgroundColor: Colors.red));
                }
              }
            },
            icon: const Icon(Icons.upload_file),
            label: const Text("Select PDF"),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), foregroundColor: Colors.white),
          )
        ],
      ),
    );
  }
}

// --- DESKTOP LAYOUT ---
class DesktopPosLayout extends StatelessWidget {
  const DesktopPosLayout({super.key});
  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(flex: 3, child: SmartSearchPanel()),
        VerticalDivider(width: 1),
        Expanded(flex: 3, child: ToolEntryPanel()),
        VerticalDivider(width: 1),
        Expanded(flex: 4, child: CartAndLoansPanel()),
      ],
    );
  }
}

// --- NEW RESPONSIVE MOBILE LAYOUT ---
class MobilePosLayout extends StatelessWidget {
  const MobilePosLayout({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    int cartCount = state.cartItems.length;

    return Scaffold(
      body: SafeArea(
        // IndexedStack seamlessly flips between panels without losing state
        child: IndexedStack(
          index: state.mobileTabIndex,
          children: const [
            SmartSearchPanel(),
            ToolEntryPanel(),
            CartAndLoansPanel(),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: state.mobileTabIndex,
        onTap: (index) => state.setMobileTab(index),
        selectedItemColor: const Color(0xFFD32F2F),
        unselectedItemColor: Colors.grey.shade600,
        backgroundColor: Colors.white,
        elevation: 10,
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.person_search), 
            label: "Student"
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.build), 
            label: "Tools"
          ),
          BottomNavigationBarItem(
            icon: Badge(
              isLabelVisible: cartCount > 0,
              label: Text('$cartCount'),
              child: const Icon(Icons.shopping_cart_checkout),
            ),
            label: "Checkout",
          ),
        ],
      ),
    );
  }
}

// --- 1. SMART SEARCH PANEL ---
class SmartSearchPanel extends StatelessWidget {
  const SmartSearchPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("1. Select Student", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 10),
          
          if (state.uploadedClasses.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: state.uploadedClasses.length,
                itemBuilder: (context, index) {
                  final className = state.uploadedClasses[index];
                  final isSelected = state.selectedClassFilter == className;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: FilterChip(
                      label: Text(className, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      selected: isSelected,
                      selectedColor: Colors.red.shade100,
                      checkmarkColor: const Color(0xFFD32F2F),
                      onSelected: (_) => state.toggleClassFilter(className),
                    ),
                  );
                },
              ),
            )
          else
            const Text("No classes loaded. Click the top right icon to import PDFs.", style: TextStyle(fontSize: 12, color: Colors.orange, fontStyle: FontStyle.italic)),
          
          const SizedBox(height: 10),

          TextField(
            autofocus: true,
            decoration: InputDecoration(
              hintText: "Search ID or Name...",
              prefixIcon: const Icon(Icons.search, color: Color(0xFFD32F2F)),
              filled: true,
              fillColor: Colors.grey.shade100,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
            ),
            onChanged: (val) => state.searchStudent(val),
          ),
          const SizedBox(height: 10),
          
          if (state.selectedStudent != null)
            Builder(
              builder: (context) {
                final student = state.selectedStudent!;
                final isBlacklisted = state.isStudentBlacklisted(student);
                final unreturnedItems = state.getUnreturnedItemsFor(student);

                return Card(
                  color: isBlacklisted ? Colors.red.shade50 : Colors.green.shade50,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8), 
                    side: BorderSide(color: isBlacklisted ? Colors.red : Colors.green, width: 2)
                  ),
                  child: Column(
                    children: [
                      ListTile(
                        title: Text(student.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text("${student.admNumber} • ${student.groupName ?? ''}"),
                        trailing: IconButton(icon: const Icon(Icons.close, color: Colors.grey), onPressed: state.clearSelection),
                      ),
                      if (isBlacklisted)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.only(bottomLeft: Radius.circular(8), bottomRight: Radius.circular(8))
                          ),
                          child: Text(
                            "⚠️ BLACKLISTED: Unreturned items (${unreturnedItems.join(', ')})",
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        )
                    ],
                  ),
                );
              }
            )
          else if (state.searchQuery.isNotEmpty && state.filteredStudents.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text("No students found.", style: TextStyle(color: Colors.red)),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: state.filteredStudents.length,
                itemBuilder: (context, index) {
                  final student = state.filteredStudents[index];
                  final isBlacklisted = state.isStudentBlacklisted(student);
                  
                  return ListTile(
                    title: Text(
                      student.name, 
                      style: TextStyle(fontWeight: FontWeight.bold, color: isBlacklisted ? Colors.red : Colors.black)
                    ),
                    subtitle: Text("${student.admNumber} • ${student.groupName}"),
                    trailing: isBlacklisted ? const Icon(Icons.warning, color: Colors.red) : null,
                    onTap: () => state.selectStudent(student),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

// --- 2. TOOL ENTRY PANEL ---
class ToolEntryPanel extends StatefulWidget {
  const ToolEntryPanel({super.key});
  @override
  State<ToolEntryPanel> createState() => _ToolEntryPanelState();
}

class _ToolEntryPanelState extends State<ToolEntryPanel> {
  final _toolCtrl = TextEditingController();

  void _submitTool(BuildContext context) {
    if (_toolCtrl.text.isNotEmpty) {
      context.read<LabState>().addToCart(_toolCtrl.text);
      _toolCtrl.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final commonKeys = ["S21", "S22", "S23", "S24", "M1", "M2"];
    
    return Container(
      color: const Color(0xFFFAFAFA),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("2. Add Tools / Keys", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 10),
          TextField(
            controller: _toolCtrl,
            decoration: InputDecoration(
              hintText: "e.g., 1 Pliers, Multimeter...",
              suffixIcon: IconButton(
                icon: const Icon(Icons.add_circle, color: Colors.green),
                onPressed: () => _submitTool(context),
              ),
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: Colors.white,
            ),
            onSubmitted: (_) => _submitTool(context),
          ),
          const SizedBox(height: 20),
          const Text("Quick Keys:", style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: commonKeys.map((keyLabel) => ActionChip(
              label: Text(keyLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
              backgroundColor: Colors.grey.shade200,
              onPressed: () => context.read<LabState>().addToCart("Key $keyLabel"),
            )).toList(),
          )
        ],
      ),
    );
  }
}

// --- 3. CART & LOANS PANEL ---
class CartAndLoansPanel extends StatelessWidget {
  const CartAndLoansPanel({super.key});

  Future<void> _shareOnWhatsApp(BuildContext context, List<TransactionLog> loans) async {
    if (loans.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No active outings to share.")));
      return;
    }

    Map<String, List<String>> defaulters = {};
    for (var log in loans) {
      defaulters.putIfAbsent(log.issuedTo, () => []).add(log.toolName);
    }

    StringBuffer sb = StringBuffer();
    sb.writeln("*🚨 KINAP MECHATRONICS LAB - UNRETURNED ITEMS 🚨*");
    sb.writeln("Please return the following tools immediately to the lab:\n");

    defaulters.forEach((student, tools) {
      sb.writeln("👤 *$student*");
      sb.writeln("🔧 Items: ${tools.join(', ')}");
      sb.writeln("---");
    });

    final url = Uri.parse("https://wa.me/?text=${Uri.encodeComponent(sb.toString())}");
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Could not launch browser for WhatsApp.")));
      }
    }
  }

  Future<void> _printDefaulters(BuildContext context, List<TransactionLog> loans) async {
    if (loans.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No active outings to print.")));
      return;
    }

    Map<String, List<String>> defaulters = {};
    for (var log in loans) {
      defaulters.putIfAbsent(log.issuedTo, () => []).add(log.toolName);
    }

    final doc = pw.Document();

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text("KINAP MECHATRONICS LAB", style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold, color: PdfColors.red800)),
              pw.Text("UNRETURNED ITEMS REPORT", style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),
              pw.Text("Generated on: ${DateTime.now().toString().split('.')[0]}"),
              pw.SizedBox(height: 20),
              pw.Table.fromTextArray(
                headers: ['Student Details', 'Items Borrowed'],
                data: defaulters.entries.map((e) => [e.key, e.value.join(', ')]).toList(),
                cellStyle: const pw.TextStyle(fontSize: 12),
                headerStyle: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
                headerDecoration: const pw.BoxDecoration(color: PdfColors.red800),
                cellPadding: const pw.EdgeInsets.all(8),
              ),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: 'KINAP_Defaulters_Report.pdf'
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabState>();
    
    bool isStudentSelected = state.selectedStudent != null;
    bool hasItemsInCart = state.cartItems.isNotEmpty;
    bool isBlacklisted = isStudentSelected && state.isStudentBlacklisted(state.selectedStudent!);
    bool canIssue = isStudentSelected && hasItemsInCart && !isBlacklisted;
    
    return Column(
      children: [
        // CART
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.white,
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("3. Checkout", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 5,
                children: state.cartItems.map((item) => Chip(
                  label: Text(item),
                  onDeleted: () => state.removeFromCart(item),
                  backgroundColor: Colors.red.shade50,
                )).toList(),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isBlacklisted ? Colors.grey : const Color(0xFFD32F2F), 
                    foregroundColor: Colors.white
                  ),
                  onPressed: canIssue && !state.isIssuing ? () => state.issueTools(context) : null,
                  icon: state.isIssuing 
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : Icon(isBlacklisted ? Icons.block : Icons.check_circle),
                  label: Text(
                    isBlacklisted ? "STUDENT BLACKLISTED" : (state.isIssuing ? "ISSUING..." : "ISSUE ITEMS"), 
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)
                  ),
                ),
              )
            ],
          ),
        ),
        const Divider(height: 1, thickness: 4, color: Color(0xFFF0F2F5)),
        
        // ACTIVE LOANS
        Expanded(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Active Outings", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.print, color: Color(0xFFD32F2F)),
                          tooltip: "Print Defaulters Report",
                          onPressed: () => _printDefaulters(context, state.activeLoans),
                        ),
                        IconButton(
                          icon: const Icon(Icons.share, color: Colors.green),
                          tooltip: "Share to WhatsApp",
                          onPressed: () => _shareOnWhatsApp(context, state.activeLoans),
                        ),
                      ],
                    )
                  ],
                ),
                const SizedBox(height: 5),
                Expanded(
                  child: ListView.separated(
                    itemCount: state.activeLoans.length,
                    separatorBuilder: (_,__) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final loan = state.activeLoans[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(loan.issuedTo.isNotEmpty ? loan.issuedTo : "Unknown Student", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        subtitle: Text(loan.toolName, style: const TextStyle(color: Color(0xFFD32F2F))),
                        trailing: ElevatedButton(
                          onPressed: () => state.returnTool(context, loan.id),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade50, foregroundColor: Colors.green.shade700, elevation: 0),
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