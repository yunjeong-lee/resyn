#!/usr/bin/python3
import sys
import os, os.path
import platform
import shutil
import time
import re
import difflib
import pickle
from subprocess import run, PIPE 
from colorama import init, Fore, Back, Style

# Globals
if platform.system() in ['Linux', 'Darwin']:
    SYNQUID_CMD = ['stack', 'exec', '--', 'synquid']            # Command to call Synquid
    TIMEOUT_CMD = ['timeout']                                   # Timeout command
    TIMEOUT = ['120']                                           # Timeout value (seconds)    
else:
    SYNQUID_CMD = ['Synquid.exe']
    TIMEOUT_CMD = ['']
    TIMEOUT = ['']

LOGFILE = 'results.log'                                         # Log file
MICRO_LOGFILE = 'micro.log'                                     # Log file
DUMPFILE = 'results'                                            # Result serialization file
MICRO_DUMPFILE = 'micro'                                        # you know
CSV_FILE = 'results.csv'                                        # CSV-output file
MICRO_CSV_FILE = 'micro.csv'                                    # CSV-output file (micro benchmarks)      
LATEX_FILE = 'results.tex'                                      # Latex-output file
MICRO_LATEX_FILE = 'micro.tex'                                  # Latex-output file (micro benchmarks)
ORACLE_FILE = 'solutions'                                       # Solutions file
MICRO_ORACLE_FILE = 'micro_solutions'                           # you know
COMMON_OPTS = ['--print-stats']                                 # Options to use for all benchmarks
RESOURCE_OPTS = []
RESOURCES_OFF_OPT = ['-r=false']                                # Option to disable resource analysis 
FNULL = open(os.devnull, 'w')                                   # Null file

PAPER_PATH = '/home/tristan/Research/resyn/paper/'

class Benchmark:
    def __init__(self, name, description, components='', options=[], np = '-'):
        self.name = name                # Id
        self.description = description  # Description (in the table)
        self.components = components    # Description of components used (in the table)
        self.options = options          # Command-line options to use for this benchmark when running in individual context
        self.num_programs = np          # Number of programs generated in the enumerate-and-check process

    def str(self):
        return self.name + ': ' + self.description + ' ' + str(self.options)

class BenchmarkGroup:
    def __init__(self, name, default_options, benchmarks):
        self.name = name                        # Id
        self.default_options = default_options  # Command-line options to use for all benchmarks in this group when running in common context
        self.benchmarks = benchmarks            # List of benchmarks in this group

MICRO_BENCHMARKS = [
    Benchmark('List-Insert', 'Annotated with uninterpreted functions', '$<$'),
    Benchmark('List-CompareCT', 'Constant-time length comparison', 'true, false, &&', ['--ct', 'f=AllArguments']),
]

ALL_BENCHMARKS = [
    BenchmarkGroup("List", [], [
        Benchmark('List-Null', 'is empty', 'true, false'),
        Benchmark('List-Elem', 'member', 'true, false, $=$, $\\neq$'),
        Benchmark('List-Stutter', 'duplicate each element'),
        Benchmark('List-Replicate', 'replicate', '0, inc, dec, $\\leq$, $\\neq$'),
        Benchmark('List-Append', 'append two lists', '', ['-m=1']),
        Benchmark('List-Concat', 'concatenate list of lists', 'append'),
        Benchmark('List-Take', 'take first $n$ elements', '0, inc, dec, $\\leq$, $\\neq$'),
        Benchmark('List-Drop', 'drop first $n$ elements', '0, inc, dec, $\\leq$, $\\neq$'),
        Benchmark('List-Delete', 'delete value', '$=$, $\\neq$'),
        Benchmark('List-Zip', 'zip'),
        Benchmark('List-Ith', '$i$-th element', '0, inc, dec, $\\leq$, $\\neq$'),
        Benchmark('List-ElemIndex', 'index of element', '0, inc, dec, $=$, $\\neq$'),
        Benchmark('List-Snoc', 'insert at end'),
        Benchmark('List-Reverse', 'reverse', 'insert at end'),
        #Benchmark('IncList-Insert', 'insert (sorted)', '$\\leq$, $\\neq$'),
        Benchmark('List-Intersect', 'intersection', '$<$, member', ['--cut-branches=false', '-f=AllArguments', '-a=2']),
        Benchmark('List-ExtractMin', 'extract minimum', '$\\leq$, $\\neq$', ['-a=2', '-m 3']),
        # Try it by hand!
        #Benchmark('TripleList-Intersect', 'three-way intersection', '$<$, member', ['-f=AllArguments', '-m=3'])
        ]),
    BenchmarkGroup("Unique list", [], [
        Benchmark('UniqueList-Insert', 'insert', '$=$, $\\neq$'),
        Benchmark('UniqueList-Delete', 'delete', '$=$, $\\neq$'),
        Benchmark('List-Nub', 'remove duplicates', 'member', []),
        Benchmark('List-Compress', 'remove adjacent dupl.', '$=$, $\\neq$', np = 3),
        Benchmark('UniqueList-Range', 'integer range', '0, inc, dec, $\\leq$, $\\neq$'),
        Benchmark('List-Partition', 'partition', '$\\leq$'),
        Benchmark('IncList-Pivot', 'append with pivot'),
        ]),
    BenchmarkGroup("Sorted list", ['-f=AllArguments'], [
        Benchmark('StrictIncList-Insert', 'insert', '$<$'),
        Benchmark('StrictIncList-Delete', 'delete', '$<$'),
        Benchmark('List-Diff', 'difference', 'member, $<$', ['--cut-branches=false', '-f=AllArguments', '-a=2']),
        #Benchmark('TripleList-Intersect', 'three-way intersection', '$<$, member',['-f=AllArguments','--cut-branches=false','-m=3'])
        #Benchmark('StrictIncList-Intersect', 'intersect', '$<$', ['-f=AllArguments', '--cut-branches=false']),
        ]),
    BenchmarkGroup("Tree",  [], [
        Benchmark('Tree-Count', 'node count', '0, 1, +'),
        Benchmark('Tree-Flatten', 'preorder', 'append'),
        ]),
    BenchmarkGroup("BST", [], [
        Benchmark('BST-Member', 'member', 'true, false, $\\leq$, $\\neq$'),
        Benchmark('BST-Insert', 'insert', '$\\leq$, $\\neq$'),
        Benchmark('BST-Delete', 'delete', '$\\leq$, $\\neq$'),
        Benchmark('BST-Sort', 'BST sort', '$\\leq$, $\\neq$')
        ]),
    BenchmarkGroup("Binary Heap", [], [
        Benchmark('BinHeap-Insert', 'insert', '$\\leq$, $\\neq$'),
        Benchmark('BinHeap-Singleton', '1-element constructor', '$\\leq$, $\\neq$'),
        Benchmark('BinHeap-Doubleton', '2-element constructor', '$\\leq$, $\\neq$'),
        Benchmark('BinHeap-Tripleton', '3-element constructor', '$\\leq$, $\\neq$')
        ])
]

class SynthesisResult:
    def __init__(self, name, time, goal_count, code_size, spec_size, measure_count, num_constraints):
        self.name = name                        # Benchmark name
        self.time = time                        # Synthesis time (seconds)
        self.goal_count = goal_count            # Number of synthesis goals 
        self.code_size = code_size              # Cumulative synthesized code size (in AST nodes)
        self.spec_size = spec_size              # Cumulative specification size (in AST nodes)
        self.measure_count = measure_count      # Number of measures defined
        self.optimized = False 
        self.nres_code_size = '-' 
        self.nres_time = -3.0 
        self.eac_time = '-'
        self.num_constraints = num_constraints

    def str(self):
        return self.name + ', ' + '{0:0.2f}'.format(self.time) + ', ' + self.goal_count + ', ' + self.code_size + ', ' + self.spec_size + ', ' + self.measure_count

def run_benchmark(name, opts, default_opts):
    '''Run benchmark name with command-line options opts (use default_opts with running the common context variant); record results in the results dictionary'''

    with open(LOGFILE, 'a+') as logfile:
      start = time.time()
      logfile.write(name + '\n')
      logfile.seek(0, os.SEEK_END)
      # Run Synquid on the benchmark:
      synthesis_res = run(SYNQUID_CMD + COMMON_OPTS + RESOURCE_OPTS + opts + [name + '.sq'], stdout=PIPE, stderr=PIPE, universal_newlines=True)
      end = time.time()

      print('{0:0.2f}'.format(end - start), end = ' ')
      if synthesis_res.returncode: # Synthesis failed
          print(Back.RED + Fore.RED + Style.BRIGHT + 'FAIL' + Style.RESET_ALL, end = ' ')
          synthesis_output = ''
          results [name] = SynthesisResult(name, (end - start), '-', '-', '-', '-', '-')
      else: # Synthesis succeeded: code metrics from the output and record synthesis time
          logfile.write(synthesis_res.stdout)
          lastLines = synthesis_res.stdout.split('\n')[-6:]
          synthesis_output = synthesis_res.stdout.split('\n')[:-6]
          goal_count = re.match("\(Goals: (\d+)\).*$", lastLines[0]).group(1)
          measure_count = re.match("\(Measures: (\d+)\).*$", lastLines[1]).group(1)
          spec_size = re.match("\(Spec size: (\d+)\).*$", lastLines[2]).group(1)
          solution_size = re.match("\(Solution size: (\d+)\).*$", lastLines[3]).group(1)                    
          num_constraints = re.match("\(Number of resource constraints: (\d+)\).*$", lastLines[4]).group(1)
          results [name] = SynthesisResult(name, (end - start), goal_count, solution_size, spec_size, measure_count, num_constraints)
          print(Back.GREEN + Fore.GREEN + Style.BRIGHT + 'OK' + Style.RESET_ALL, end = ' ')

      variant_options = [   # Command-line options to use for each variant of Synquid
            ('nres', opts + RESOURCES_OFF_OPT),
        ]

      # Run each variant: (now there's only one, should probably change this...)
      for (variant_id, opts) in variant_options:
          run_version(name, variant_id, opts, logfile, str(synthesis_output), results)

      print()

def run_micro_benchmark(name, opts, default_opts):
    '''Run benchmark name with command-line options opts (use default_opts with running the common context variant); record results in the results dictionary'''

    with open(MICRO_LOGFILE, 'a+') as logfile:
      start = time.time()
      logfile.write(name + '\n')
      logfile.seek(0, os.SEEK_END)
      # Run Synquid on the benchmark:
      synthesis_res = run(SYNQUID_CMD + COMMON_OPTS + RESOURCE_OPTS + opts + [name + '.sq'], stdout=PIPE, stderr=PIPE, universal_newlines=True)
      end = time.time()

      print('{0:0.2f}'.format(end - start), end = ' ')
      if synthesis_res.returncode: # Synthesis failed
          print(Back.RED + Fore.RED + Style.BRIGHT + 'FAIL' + Style.RESET_ALL, end = ' ')
          synthesis_output = ''
          micro_results [name] = SynthesisResult(name, (end - start), '-', '-', '-', '-', '-')
      else: # Synthesis succeeded: code metrics from the output and record synthesis time
          logfile.write(synthesis_res.stdout)
          lastLines = synthesis_res.stdout.split('\n')[-6:]
          synthesis_output = synthesis_res.stdout.split('\n')[:-6]
          goal_count = re.match("\(Goals: (\d+)\).*$", lastLines[0]).group(1)
          measure_count = re.match("\(Measures: (\d+)\).*$", lastLines[1]).group(1)
          spec_size = re.match("\(Spec size: (\d+)\).*$", lastLines[2]).group(1)
          solution_size = re.match("\(Solution size: (\d+)\).*$", lastLines[3]).group(1)                    
          num_constraints = re.match("\(Number of resource constraints: (\d+)\).*$", lastLines[4]).group(1)
          micro_results [name] = SynthesisResult(name, (end - start), goal_count, solution_size, spec_size, measure_count, num_constraints)
          print(Back.GREEN + Fore.GREEN + Style.BRIGHT + 'OK' + Style.RESET_ALL, end = ' ')

      variant_options = [   # Command-line options to use for each variant of Synquid
            ('nres', opts + RESOURCES_OFF_OPT),
        ]

      # Run each variant: (now there's only one, should probably change this...)
      for (variant_id, opts) in variant_options:
          run_version(name, variant_id, opts, logfile, str(synthesis_output), micro_results)

      print()

def run_version(name, variant_id, variant_opts, logfile, with_res, results_file):
    '''Run benchmark name using command-line options variant_opts and record it as a Synquid variant variant_id in the results dictionary'''
    start = time.time()
    logfile.seek(0, os.SEEK_END)
    # Run Synquid on the benchmark, mute output:
    synthesis_res = run(TIMEOUT_CMD + TIMEOUT + SYNQUID_CMD + COMMON_OPTS +
        variant_opts + [name + '.sq'], stdout=PIPE, stderr=PIPE, universal_newlines=True)
    end = time.time()
    lastLines = synthesis_res.stdout.split('\n')[-6:]
    solution_size = re.match("\(Solution size: (\d+)\).*$", lastLines[3]).group(1)   

    print('{0:0.2f}'.format(end - start), end = ' ')
    if synthesis_res.returncode == 124:  # Timeout: record timeout
      print(Back.RED + Fore.RED + Style.BRIGHT + 'TIMEOUT' + Style.RESET_ALL, end = ' ')
      results_file[name].nres_time = -1
    elif synthesis_res.returncode: # Synthesis failed: record failure
      print(Back.RED + Fore.RED + Style.BRIGHT + 'FAIL' + Style.RESET_ALL, end = ' ')
      results_file[name].nres_time = -2
    else: # Synthesis succeeded: record time for variant
      results_file[name].nres_time = (end - start)
      without_res = synthesis_res.stdout.split('\n')[:-6]
      # Compare outputs to see if resources led to any optimization
      diff = difflib.unified_diff(with_res, str(without_res))
      print(Back.GREEN + Fore.GREEN + Style.BRIGHT + 'OK' + Style.RESET_ALL, end=' ')
      try:
          first = next(diff)
          if with_res != '': print(Back.GREEN + Fore.GREEN + Style.BRIGHT + 'OPTIMIZED' + Style.RESET_ALL, end=' ')
          results_file[name].optimized = True
          results_file[name].nres_code_size = solution_size
      except StopIteration:
          print('Unchanged', end=' ')
      
def format_time(t):
    if t < 0:
        return '-'
    else:
        return '{0:0.2f}'.format(t)

def write_micro_csv():
    '''Generate CSV file for micro benchmark'''
    with open(MICRO_CSV_FILE, 'w') as outfile:
        for group in groups:
            for b in group.benchmarks:
                outfile.write (b.name + ',')
                result = micro_results [b.name]
                optstr = 'True' if result.optimized else '-'
                outfile.write (result.spec_size + ',')
                outfile.write (result.code_size + ',')
                outfile.write (format_time(result.time) + ',')
                outfile.write (format_time(result.nres_time) + ',')
                outfile.write (result.nres_code_size + ',')
                outfile.write (str(b.num_programs) + ',')
                outfile.write (result.eac_time + ',')
                #outfile.write (optstr + ',')
                outfile.write ('\n')

def write_csv():
    '''Generate CSV file from the results dictionary'''
    with open(CSV_FILE, 'w') as outfile:
        for group in groups:
            for b in group.benchmarks:
                outfile.write (b.name + ',')
                result = results [b.name]
                optstr = 'True' if result.optimized else '-'
                outfile.write (result.spec_size + ',')
                outfile.write (result.code_size + ',')
                outfile.write (format_time(result.time) + ',')
                outfile.write (format_time(result.nres_time) + ',')
                outfile.write (result.nres_code_size + ',')
                outfile.write (str(b.num_programs) + ',')
                outfile.write (result.eac_time + ',')
                #outfile.write (optstr + ',')
                outfile.write ('\n')

def write_micro_latex():
    '''Generate Latex table from the results dictionary'''
    
    total_count = 0
    to_def = 0
    to_nres = 0

    with open(MICRO_LATEX_FILE, 'w') as outfile:
        for group in groups:
            outfile.write ('\multirow{')
            outfile.write (str(group.benchmarks.__len__()))
            outfile.write ('}{*}{\\parbox{1cm}{\\vspace{-0.85\\baselineskip}\center{')
            outfile.write (group.name)
            outfile.write ('}}}')            

            for b in group.benchmarks:
                result = micro_results [b.name]                
                optstr = 'Yes' if result.optimized else '-'
                row = \
                    ' & ' + b.description +\
                    ' & ' + result.goal_count +\
                    ' & ' + b.components + \
                    ' & ' + result.measure_count + \
                    ' & ' + result.code_size + \
                    ' & ' + format_time(result.time) + \
                    ' & ' + format_time(result.nres_time) + \
                    ' & ' + result.nres_code_size + \
                    ' & ' + str(b.num_programs) + \
                    ' & ' + str(result.eac_time) + ' \\\\'
                    #' & ' + optstr + ' \\\\'
                outfile.write (row)
                outfile.write ('\n')
                
                total_count = total_count + 1
                if result.nres_time < 0.0:
                   to_nres = to_nres + 1 
                
            outfile.write ('\\hline')
            
    print('Total:', total_count)
    print('TO nres:', to_nres)

def write_latex():
    '''Generate Latex table from the results dictionary'''
    
    total_count = 0
    to_def = 0
    to_nres = 0

    with open(LATEX_FILE, 'w') as outfile:
        for group in groups:
            outfile.write ('\multirow{')
            outfile.write (str(group.benchmarks.__len__()))
            outfile.write ('}{*}{\\parbox{1cm}{\\vspace{-0.85\\baselineskip}\center{')
            outfile.write (group.name)
            outfile.write ('}}}')            

            for b in group.benchmarks:
                result = results [b.name]                
                optstr = 'Yes' if result.optimized else '-'
                row = \
                    ' & ' + b.description +\
                    ' & ' + result.goal_count +\
                    ' & ' + b.components + \
                    ' & ' + result.measure_count + \
                    ' & ' + result.code_size + \
                    ' & ' + format_time(result.time) + \
                    ' & ' + format_time(result.nres_time) + \
                    ' & ' + result.nres_code_size + \
                    ' & ' + str(b.num_programs) + \
                    ' & ' + str(result.eac_time) + ' \\\\'
                    #' & ' + optstr + ' \\\\'
                outfile.write (row)
                outfile.write ('\n')
                
                total_count = total_count + 1
                if result.nres_time < 0.0:
                   to_nres = to_nres + 1 
                
            outfile.write ('\\hline')
            
    print('Total:', total_count)
    print('TO nres:', to_nres)
    
def cmdline():
    import argparse
    a = argparse.ArgumentParser()
    a.add_argument('--medium', action='store_true')
    a.add_argument('--small', action='store_true')
    return a.parse_args()    

if __name__ == '__main__':
    init()
    
    cl_opts = cmdline()
    
    # Check if there are serialized results
    if os.path.isfile(DUMPFILE):
        results = pickle.load(open(DUMPFILE, 'rb'))
    else:
        results = dict()

    if os.path.isfile(MICRO_DUMPFILE):
        micro_results = pickle.load(open(MICRO_DUMPFILE, 'rb'))
    else:
        micro_results = dict()

    # Delete old log file
    if os.path.isfile(LOGFILE):
      os.remove(LOGFILE)

    if os.path.isfile(MICRO_LOGFILE):
      os.remove(MICRO_LOGFILE)

    # Run experiments
    groups = ALL_BENCHMARKS[:1] if cl_opts.small else ALL_BENCHMARKS
        
    for group in groups:
        for b in group.benchmarks: 
            if b.name in results:
                print(b.str() + Back.YELLOW + Fore.YELLOW + Style.BRIGHT + 'SKIPPED' + Style.RESET_ALL)
            else:
                print(b.str())
                run_benchmark(b.name, b.options, group.default_options)
                with open(DUMPFILE, 'wb') as data_dump:
                    pickle.dump(results, data_dump)    

    for b in MICRO_BENCHMARKS:
        if b.name in micro_results:
            print(b.str() + Back.YELLOW + Fore.YELLOW + Style.BRIGHT + 'SKIPPED' + Style.RESET_ALL)
        else:
            print(b.str())
            run_micro_benchmark(b.name, b.options, group.default_options)
            with open(MICRO_DUMPFILE, 'wb') as data_dump:
                pickle.dump(micro_results, data_dump)    

            
    # Generate CSV
    write_csv()            
    # Generate Latex table
    write_latex()

    write_micro_csv()
    write_micro_latex()

    # Compare with previous solutions and print the diff
    if os.path.isfile(ORACLE_FILE) and (not cl_opts.small):
        fromlines = open(ORACLE_FILE).readlines()
        tolines = open(LOGFILE, 'U').readlines()
        diff = difflib.unified_diff(fromlines, tolines, n=0)
        print()
        sys.stdout.writelines(diff)

    if os.path.isfile(MICRO_ORACLE_FILE) and (not cl_opts.small):
        fromlines = open(MICRO_ORACLE_FILE).readlines()
        tolines = open(MICRO_LOGFILE, 'U').readlines()
        diff = difflib.unified_diff(fromlines, tolines, n=0)
        print()
        sys.stdout.writelines(diff)


    # Copy results to paper directory
    shutil.copy('./' + LATEX_FILE, PAPER_PATH + LATEX_FILE)
    shutil.copy('./' + MICRO_LATEX_FILE, PAPER_PATH + MICRO_LATEX_FILE)