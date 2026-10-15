#!/usr/bin/env python3
"""Verify the actual Android signer and extracted iOS signer against P256."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[2]
plugin=root/'packages/bloom_provision'
message='bloom-local-admin-auth-v1|frame-1|'+'a'*32+'|1'
key='0'*63+'1'
with tempfile.TemporaryDirectory(prefix='bloom-owner-sign-') as temporary:
    tmp=Path(temporary)
    swift=(plugin/'ios/Classes/BloomProvisionPlugin.swift').read_text()
    branch=swift[swift.index('        if call.method == "sign_admin"'):swift.index('        if call.method == "disconnect"')]
    wrapper='''import Foundation
import CryptoKit
struct FlutterError: Error { let code:String; let message:String; let details:String? }
struct Call { let method="sign_admin"; let arguments:Any }
func sign(_ arguments:[String:Any])->Any? {
 var output:Any?=nil
 let call=Call(arguments:arguments)
 let result:(Any?)->Void={output=$0}
 func execute(){ BRANCH }
 execute();return output
}
let message="MESSAGE"
let key="KEY"
let text=sign(["message":message,"key":key]) as! String
let signature=try P256.Signing.ECDSASignature(derRepresentation:Data(base64Encoded:text)!)
let privateKey=try P256.Signing.PrivateKey(rawRepresentation:Data(Array(repeating:0,count:31)+[1]))
assert(privateKey.publicKey.isValidSignature(signature,for:Data(message.utf8)))
assert(!privateKey.publicKey.isValidSignature(signature,for:Data((message+"wrong").utf8)))
assert(sign(["message":message,"key":String(repeating:"0",count:64)]) is FlutterError)
print("PASS 实际 iOS 主人签名、篡改拒绝和非法私钥拒绝")
'''.replace('BRANCH',branch).replace('MESSAGE',message).replace('KEY',key)
    (tmp/'test.swift').write_text(wrapper)
    subprocess.run(['xcrun','swiftc','-target','x86_64-apple-macosx13.0',str(tmp/'test.swift'),'-o',str(tmp/'swift-test')],check=True)
    subprocess.run([str(tmp/'swift-test')],check=True)
    java='''import com.bloom.provision.FrameAdminCrypto;
import java.security.*;
import java.security.spec.*;
public class CryptoTest {
 public static void main(String[] args)throws Exception {
  byte[] prefix=new byte[]{0x30,0x59,0x30,0x13,0x06,0x07,0x2a,(byte)0x86,0x48,(byte)0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,(byte)0x86,0x48,(byte)0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0};
  String point="046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5";
  byte[] der=new byte[91];System.arraycopy(prefix,0,der,0,26);
  for(int i=0;i<65;i++)der[26+i]=(byte)Integer.parseInt(point.substring(i*2,i*2+2),16);
  PublicKey publicKey=KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(der));
  String message="MESSAGE";
  byte[] signature=FrameAdminCrypto.sign(message,"KEY");
  Signature verifier=Signature.getInstance("SHA256withECDSA");verifier.initVerify(publicKey);verifier.update(message.getBytes("UTF-8"));
  if(!verifier.verify(signature))throw new AssertionError();
  verifier.initVerify(publicKey);verifier.update((message+"wrong").getBytes("UTF-8"));if(verifier.verify(signature))throw new AssertionError();
  try{FrameAdminCrypto.sign(message,"0");throw new AssertionError();}catch(IllegalArgumentException expected){}
  System.out.println("PASS 实际 Android 主人签名、篡改拒绝和非法私钥拒绝");
 }
}'''.replace('MESSAGE',message).replace('KEY',key)
    (tmp/'CryptoTest.java').write_text(java)
    subprocess.run(['javac','-encoding','UTF-8','-d',str(tmp),str(plugin/'android/src/main/java/com/bloom/provision/FrameAdminCrypto.java'),str(tmp/'CryptoTest.java')],check=True)
    subprocess.run(['java','-cp',str(tmp),'CryptoTest'],check=True)
