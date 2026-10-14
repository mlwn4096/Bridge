package dev.bridge.airdroplab;

import android.security.keystore.*;
import java.math.BigInteger;
import java.net.Socket;
import java.security.*;
import java.security.cert.*;
import java.util.*;
import javax.net.ssl.*;
import javax.security.auth.x500.X500Principal;

/** Lab-only Everyone-mode identity. No Apple ID records or Contacts Only emulation. */
final class Tls {
    static final String ALIAS = "bridge-airdrop-lab-v1";
    static String fingerprint(X509Certificate certificate) throws CertificateException {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded());
            StringBuilder out = new StringBuilder(); for (byte b : digest) out.append(String.format(Locale.ROOT, "%02x", b & 255)); return out.toString();
        } catch (GeneralSecurityException e) { throw new CertificateException(e); }
    }
    static SSLContext context(String pin, boolean server) throws GeneralSecurityException, java.io.IOException {
        KeyManager[] keys = null;
        {
            KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
            if (!store.containsAlias(ALIAS)) {
                KeyPairGenerator generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore");
                generator.initialize(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY)
                    .setKeySize(2048).setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA512)
                    .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1, KeyProperties.SIGNATURE_PADDING_RSA_PSS)
                    .setCertificateSubject(new X500Principal("CN=Bridge AirDrop Lab"))
                    .setCertificateSerialNumber(BigInteger.ONE).setCertificateNotBefore(new Date(System.currentTimeMillis() - 86400000L))
                    .setCertificateNotAfter(new Date(System.currentTimeMillis() + 3650L * 86400000)).build());
                generator.generateKeyPair();
            }
            final PrivateKey key = (PrivateKey) store.getKey(ALIAS, null);
            final X509Certificate[] chain = Arrays.copyOf(store.getCertificateChain(ALIAS), store.getCertificateChain(ALIAS).length, X509Certificate[].class);
            keys = new KeyManager[] {new X509ExtendedKeyManager() {
                public String[] getClientAliases(String t, Principal[] i) { return t.startsWith("RSA") ? new String[] {ALIAS} : null; }
                public String chooseClientAlias(String[] t, Principal[] i, Socket s) { for (String type : t) if (type.startsWith("RSA")) return ALIAS; return null; }
                public String[] getServerAliases(String t, Principal[] i) { return t.startsWith("RSA") ? new String[] {ALIAS} : null; }
                public String chooseServerAlias(String t, Principal[] i, Socket s) { return t.startsWith("RSA") ? ALIAS : null; }
                public X509Certificate[] getCertificateChain(String a) { return ALIAS.equals(a) ? chain.clone() : null; }
                public PrivateKey getPrivateKey(String a) { return ALIAS.equals(a) ? key : null; }
            }};
        }
        X509TrustManager trust = new X509TrustManager() {
            public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            public void checkClientTrusted(X509Certificate[] c, String a) throws CertificateException { check(c); }
            public void checkServerTrusted(X509Certificate[] c, String a) throws CertificateException { check(c); }
            private void check(X509Certificate[] c) throws CertificateException {
                if (c == null || c.length < 1 || c.length > 16) throw new CertificateException("Invalid certificate chain");
                c[0].checkValidity();
                if (pin != null && !MessageDigest.isEqual(pin.getBytes(java.nio.charset.StandardCharsets.US_ASCII), fingerprint(c[0]).getBytes(java.nio.charset.StandardCharsets.US_ASCII))) throw new CertificateException("Receiver certificate changed; probe again");
            }
        };
        SSLContext context = SSLContext.getInstance("TLS"); context.init(keys, new TrustManager[] {trust}, new SecureRandom()); return context;
    }
}
