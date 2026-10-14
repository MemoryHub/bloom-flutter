#!/usr/bin/env python3
"""Check stale BLE event rejection using the actual SDK event and owner predicate."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
vendor = root / 'vendor/android/java/com/espressif/provisioning'
source = (vendor / 'ESPDevice.java').read_text()
start = source.index('    public boolean ownsConnectionEvent(')
method = source[start:source.index('\n    }', start) + 6]
java_home = os.environ.get('JAVA_HOME')
javac = str(Path(java_home) / 'bin/javac') if java_home else shutil.which('javac')
java = str(Path(java_home) / 'bin/java') if java_home else shutil.which('java')
if not javac or not java:
    raise RuntimeError('JDK required: set JAVA_HOME or add java/javac to PATH')
with tempfile.TemporaryDirectory(prefix='bloom-ble-events-') as tmp:
    tmp = Path(tmp)
    bundle = tmp / 'android/os/Bundle.java'
    bundle.parent.mkdir(parents=True)
    bundle.write_text('package android.os; public class Bundle {}')
    event = tmp / 'com/espressif/provisioning/DeviceConnectionEvent.java'
    event.parent.mkdir(parents=True)
    event.write_text((vendor / 'DeviceConnectionEvent.java').read_text())
    fixture = tmp / 'Check.java'
    fixture.write_text("""import com.espressif.provisioning.DeviceConnectionEvent;
public class Check {
    static class Owner { final Object transport = new Object();
""" + method + """
    }
    static void expect(boolean result, String name) {
        if (!result) throw new AssertionError(name);
        System.out.println("PASS " + name);
    }
    public static void main(String[] args) {
        Owner old = new Owner(), active = new Owner();
        expect(active.ownsConnectionEvent(new DeviceConnectionEvent((short) 1, active)), "current device event");
        expect(active.ownsConnectionEvent(new DeviceConnectionEvent((short) 1, active.transport)), "current BLE transport event");
        expect(!active.ownsConnectionEvent(new DeviceConnectionEvent((short) 3, old.transport)), "previous transport disconnect is ignored");
        expect(!active.ownsConnectionEvent(new DeviceConnectionEvent((short) 2, old)), "previous device failure is ignored");
        expect(!active.ownsConnectionEvent(new DeviceConnectionEvent((short) 1)), "uncorrelated global event is ignored");
    }
}
""")
    subprocess.run([javac, '-d', str(tmp), str(bundle), str(event), str(fixture)], check=True)
    subprocess.run([java, '-cp', str(tmp), 'Check'], check=True)
