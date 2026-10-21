import com.bloom.widget_bridge.BloomInstallIdentity;
import java.nio.file.Files;
import java.io.File;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.Callable;
import java.util.ArrayList;

public class TestInstallIdentity {
    public static void main(String[] args) throws Exception {
        for (String id : new String[]{null,"","unknown","0000000000000000","ffffffffffffffff","9774d56d682e549c"}) {
            if (BloomInstallIdentity.usableAndroidId(id)) throw new AssertionError("placeholder accepted");
        }
        if (!BloomInstallIdentity.usableAndroidId("f036891abcde1234")) throw new AssertionError("valid ID rejected");
        File a = Files.createTempDirectory("bloom-phone-a-").toFile();
        File b = Files.createTempDirectory("bloom-phone-b-").toFile();
        Map<String,String> first = BloomInstallIdentity.credentials(a);
        if (!first.equals(BloomInstallIdentity.credentials(a))) throw new AssertionError("identity changed");
        Map<String,String> second = BloomInstallIdentity.credentials(b);
        if (first.get("deviceId").equals(second.get("deviceId")) || first.get("deviceToken").equals(second.get("deviceToken"))) {
            throw new AssertionError("independent installations share identity");
        }
        var pool = Executors.newFixedThreadPool(4);
        try {
            var tasks = new ArrayList<Callable<Map<String,String>>>();
            for (int i=0;i<16;i++) tasks.add(() -> BloomInstallIdentity.credentials(a));
            for (var result : pool.invokeAll(tasks)) if (!first.equals(result.get())) throw new AssertionError("racing identity");
        } finally { pool.shutdownNow(); }
        File corrupt = Files.createTempDirectory("bloom-phone-corrupt-").toFile();
        Files.writeString(new File(corrupt,"bloom-install-identity-v3.properties").toPath(),"partial");
        try {
            BloomInstallIdentity.credentials(corrupt);
            throw new AssertionError("corrupt identity silently replaced");
        } catch (java.io.IOException expected) {}
        for (File directory : new File[]{a,b,corrupt}) {
            for (File file : directory.listFiles()) Files.delete(file.toPath());
            Files.delete(directory.toPath());
        }
        System.out.println("PASS: placeholder rejection, independent identities/proofs, persistence, 16 concurrent reads, corrupt-file refusal");
    }
}
