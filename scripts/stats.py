import paramiko
import os
import subprocess
import time
import signal
import argparse
import sys

HOST = "cab1"
TGOUT = "./outputs/tg_out.txt"
MG_DIR = os.path.expanduser("~/MoonGen")

DEFAULT_RATE = 10000
NO_CONG_RATE = 250

def connect():
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh_config = paramiko.SSHConfig()
    user_config_file = os.path.expanduser("~/.ssh/config") 
    if os.path.exists(user_config_file):
        with open(user_config_file) as f:
            ssh_config.parse(f)

    cfg = {"hostname": "",
           "username" : "",
           "port" : 22,}

    for key, val in ssh_config.lookup(HOST).items():
        if key == "hostname":
            cfg[key] = val
        elif key == "user":
            cfg["username"] = val
        elif key == "port":
            cfg[key] = int(val)
        elif key == "identityfile":
            cfg["key_filename"] = os.path.expanduser(value[0])
    client.connect(**cfg)
    return client


def run_dut(client, respond, vm_id):
    stdin, stdout, stderr = client.exec_command('python scripts/stats.py %d %d' % (respond, vm_id))

    dut_stdout = []
    for line in stdout:
        dut_stdout.append(line.strip())
  
    dut_stderr = []
    for line in stderr:
        if len(line.strip()) > 0:
            dut_stderr.append(line.strip())

    if len(dut_stderr) > 0:
        for l in dut_stderr:
            print l 
        return None
       
    cpu_usage = 0
    for line in dut_stdout:
        if "CPU" in line:
            cpu_usage = float(line.strip().split()[1].strip())
            break
    if cpu_usage == 0:
        return None
    
    mean, stdev = 0, 0
    for line in dut_stdout:
        if "RX Stat" in line:
            mean = int(line.strip().split()[2].strip())
            stdev = int(line.strip().split()[3].strip())
            break
    if mean == 0:
        return None

    return (mean, stdev, cpu_usage)

def run(vm_id, tx_rate, tx_pkt_size, respond):
    
    # Run the traffic generator
    tg_out = open(TGOUT, 'w')
    mg = os.path.join(MG_DIR, "build/MoonGen")
    mg_src = os.path.join(MG_DIR, "examples/cocoa_generator.lua")
    p = subprocess.Popen([mg, mg_src, "0", "1", "%d" % vm_id, 
                                      "-r", str(tx_rate),
                                      "-s", tx_pkt_size], 
                          stdout = tg_out, shell=False)     
   
    time.sleep(5)
    tx_started = False
    while not tx_started:
        time.sleep(1)
        tp = subprocess.Popen(["tail", "-n", "1", TGOUT], shell=False, stdout = subprocess.PIPE)
        (line, _) = tp.communicate()
        tx_started = "[Queue " in line and "Mpps" in line and not "StdDev" in line
    print "TX Started"
    
    client = connect()
    dut_out = run_dut(client, respond, vm_id)
    client.close()
    os.kill(p.pid, signal.SIGINT)
    tg_out.close()
    time.sleep(2)

    if dut_out is None:
        print "Error in DUT"
        return None

    else:
        tp = subprocess.Popen(["tail", "-n", "2", TGOUT], shell=False, stdout = subprocess.PIPE)
        (out, _) = tp.communicate()
        lines = out.split('\n')
        rtt_mean, rtt_stdev = 0, 0
        for line in lines:
            if "udp traffic" in line:
                rtt_mean = float(line.strip().split()[5].strip()) 
                rtt_stdev = float(line.strip().split()[8].strip())

        outs = [x for x in dut_out]
        outs.append(rtt_mean)
        outs.append(rtt_stdev)
        return outs

def cleanup():
    p = subprocess.Popen(["ps -A | grep MoonGen"], shell=True, stdout = subprocess.PIPE)
    (out, _) = p.communicate()
    for line in out.split('\n'):
        try:
            pid = int(line.strip().split()[0].strip())
            os.kill(pid, signal.SIGINT)
        except:
            continue

def experiment(pkt_size, vm_id):
    
    ## Default Rate, No Response ##
    print "---------------------------------------"
    results = [0, 0, 0]
    print "running default, no response"
    out = run(vm_id, DEFAULT_RATE, pkt_size, 0)
    if not out is None:
        results[-3:] = [float(out[0])/1000,
                        float(out[1])/1000,
                        out[2]]
    print results
    time.sleep(2)
    cleanup()

    ## No Congestion, No Respone ##
    print "---------------------------------------"
    results.extend([0])
    print "running no congestion, no response"
    out = run(vm_id, NO_CONG_RATE, pkt_size, 0)
    if not out is None:
        results[-1] = out[2]
    print results
    time.sleep(2)
    cleanup() 
    
    ## Default, Respone ##
    print "---------------------------------------"
    results.extend([0] * 5)
    print "running default, response"
    out = run(vm_id, DEFAULT_RATE, pkt_size, 1)
    if not out is None:
        results[-5:] = [float(out[0])/1000,
                        float(out[1])/1000,
                        out[2],
                        out[3]/1000,
                        out[4]/1000]
    print results
    time.sleep(2)
    cleanup() 
    
    ## No Congestion, Respone ##
    print "---------------------------------------"
    results.extend([0] * 3)
    print "running no congestion, response"
    out = run(vm_id, NO_CONG_RATE, pkt_size, 1)
    if not out is None:
        results[-3:-1] = [out[3]/1000, out[4]/1000]
        results[-1] = out[2] 
    print results
    time.sleep(2)
    cleanup() 
    
    print "---------------------------------------"
    res_str = "%.1f\t%.2f\t%.1f\t%.1f\t%.1f\t%.2f\t%.1f\t%d\t%d\t%d\t%d\t%.1f\n" % tuple(results)
    print "DONE"
    return res_str 
    
    #return "hi"

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description = "RX Throughput and RTT Tests")
    parser.add_argument("-o --out", action = "store", dest = "out", required = True)
    parser.add_argument("--vm", action = "store", type = int, dest = "vm", required = True)
    args = parser.parse_args(sys.argv[1:])
 
    f = open(args.out, "w")
    pkt_sizes = ["64", "128", "256", "512", "1024", "1500", "r"]
    #pkt_sizes = ["64"]
    for p in pkt_sizes:
        print "======================================="
        print "Packet Size", p, ", VM", args.vm
        s = experiment(p, args.vm)
        print s
        print "======================================="
        f.write(s)
    f.close()
