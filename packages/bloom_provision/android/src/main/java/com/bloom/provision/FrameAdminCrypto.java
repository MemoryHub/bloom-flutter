package com.bloom.provision;

import java.math.BigInteger;
import java.security.AlgorithmParameters;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPrivateKeySpec;
import java.nio.charset.StandardCharsets;

/** Local owner signing. No Bluetooth, HTTP or persistent storage side effects. */
public final class FrameAdminCrypto {
    public static byte[] sign(String message, String key) throws Exception {
        if (key == null || !key.matches("[a-f0-9]{64}") || message == null || message.length() > 256) {
            throw new IllegalArgumentException("local_admin_denied");
        }
        AlgorithmParameters parameters = AlgorithmParameters.getInstance("EC");
        parameters.init(new ECGenParameterSpec("secp256r1"));
        ECParameterSpec curve = parameters.getParameterSpec(ECParameterSpec.class);
        BigInteger scalar = new BigInteger(key, 16);
        if (scalar.signum() <= 0 || scalar.compareTo(curve.getOrder()) >= 0) throw new IllegalArgumentException("local_admin_denied");
        PrivateKey privateKey = KeyFactory.getInstance("EC").generatePrivate(new ECPrivateKeySpec(scalar, curve));
        Signature signer = Signature.getInstance("SHA256withECDSA");
        signer.initSign(privateKey);
        signer.update(message.getBytes(StandardCharsets.UTF_8));
        return signer.sign();
    }
}
