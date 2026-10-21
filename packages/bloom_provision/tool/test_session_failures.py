#!/usr/bin/env python3
"""Run the production session against failures before and during a handshake."""
from pathlib import Path
import os, shutil, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
vendor = root / 'vendor/android/java/com/espressif/provisioning'
home = os.environ.get('JAVA_HOME')
javac = str(Path(home) / 'bin/javac') if home else shutil.which('javac')
java = str(Path(home) / 'bin/java') if home else shutil.which('java')
fixture = r'''
import com.espressif.provisioning.Session;
import com.espressif.provisioning.security.Security;
import com.espressif.provisioning.transport.Transport;
import com.espressif.provisioning.listeners.ResponseListener;
public class CheckSession {
 static class Crypto implements Security {
  int calls; boolean firstFailure;
  final RuntimeException error = new IllegalStateException("fixture");
  public byte[] getNextRequestInSession(byte[] data){
   if(firstFailure || ++calls==2)throw error;
   return new byte[]{1};
  }
  public byte[] encrypt(byte[] b){return b;}
  public byte[] decrypt(byte[] b){return b;}
 }
 static class Wire implements Transport {
  int sends;
  public void sendConfigData(String p,byte[] d,ResponseListener l){
   sends++;l.onSuccess(new byte[]{2});
  }
 }
 static class Result implements Session.SessionListener {
  int successes,failures; Exception failure;
  public void OnSessionEstablished(){successes++;}
  public void OnSessionEstablishFailed(Exception e){failures++;failure=e;}
 }
 public static void main(String[] args){
  for(boolean initial:new boolean[]{true,false}){
   Crypto crypto=new Crypto();crypto.firstFailure=initial;
   Wire wire=new Wire();Session session=new Session(wire,crypto);
   Result result=new Result();session.init(null,result);
   if(result.successes!=0 || result.failures!=1 || result.failure!=crypto.error
      || session.isEstablished() || wire.sends!=(initial?0:1))
    throw new AssertionError("Handshake failure was lost or falsely succeeded");
  }
  System.out.println("PASS initial and response handshake exceptions fail exactly once and retain their cause");
 }
}
'''
with tempfile.TemporaryDirectory(prefix='bloom-session-failures-') as directory:
    tmp=Path(directory)
    for name in ['Session.java','security/Security.java','transport/Transport.java','listeners/ResponseListener.java']:
        target=tmp/'com/espressif/provisioning'/name
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_text((vendor/name).read_text())
    (tmp/'com/espressif/provisioning/ESPConstants.java').write_text('package com.espressif.provisioning; public class ESPConstants { public static final String HANDLER_PROV_SESSION="prov-session"; }')
    (tmp/'CheckSession.java').write_text(fixture)
    subprocess.run([javac,'-d',str(tmp),*[str(p) for p in tmp.rglob('*.java')]],check=True)
    subprocess.run([java,'-cp',str(tmp),'CheckSession'],check=True)
