import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.UUID;
import javax.net.ssl.HttpsURLConnection;

/** Real shell-UID HTTP/TLS probe used by the physical Android VPN gate. */
public final class MobileAndroidCapturedNetworkProbe {
    private static final int TIMEOUT_MILLIS = 8_000;

    private static final class Response {
        final int status;
        final String body;

        Response(int status, String body) {
            this.status = status;
            this.body = body;
        }
    }

    private static Response fetch(String rawUrl, boolean requireTls) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(rawUrl).openConnection();
        if (requireTls && !(connection instanceof HttpsURLConnection)) {
            throw new IllegalArgumentException("public probe URL is not HTTPS");
        }
        connection.setConnectTimeout(TIMEOUT_MILLIS);
        connection.setReadTimeout(TIMEOUT_MILLIS);
        connection.setInstanceFollowRedirects(true);
        connection.setRequestProperty("Connection", "close");
        connection.setRequestProperty("User-Agent", "nvpn-physical-release-gate");
        int status = connection.getResponseCode();
        InputStream stream =
            status >= 400 ? connection.getErrorStream() : connection.getInputStream();
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        if (stream != null) {
            byte[] buffer = new byte[4_096];
            int count;
            while ((count = stream.read(buffer)) != -1 && body.size() < 65_536) {
                body.write(buffer, 0, count);
            }
            stream.close();
        }
        connection.disconnect();
        return new Response(status, body.toString(StandardCharsets.UTF_8.name()));
    }

    public static void main(String[] args) throws Exception {
        if (args.length == 4 && args[0].equals("--udp-echo")) {
            udpEcho(args[1], Integer.parseInt(args[2]), args[3]);
            return;
        }
        if (args.length == 1) {
            Response direct = fetch(args[0], true);
            if (direct.status < 200 || direct.status >= 400) {
                throw new IllegalStateException("direct HTTPS status=" + direct.status);
            }
            System.out.println("directHttpsStatus=" + direct.status);
            return;
        }
        if (args.length != 5) {
            throw new IllegalArgumentException(
                "expected PUBLIC_HTTPS_URL or CONTROLLED_HTTP_URL TOKEN "
                    + "PUBLIC_HTTPS_URL EXIT_SOURCE_URL EXPECTED_EXIT_SOURCE_IP"
            );
        }
        Response controlled = fetch(args[0], false);
        if (controlled.status != 200 || !controlled.body.trim().equals(args[1])) {
            throw new IllegalStateException(
                "controlled response mismatch status=" + controlled.status
            );
        }
        Response secure = fetch(args[2], true);
        if (secure.status < 200 || secure.status >= 400) {
            throw new IllegalStateException("HTTPS status=" + secure.status);
        }
        Response exitSource = fetch(args[3], true);
        String exitSourceIp = exitSource.body.trim();
        if (exitSource.status != 200 || !exitSourceIp.equals(args[4])) {
            throw new IllegalStateException(
                "exit source mismatch status=" + exitSource.status
                    + " actual=" + exitSourceIp
            );
        }
        System.out.println(
            "capturedHttpStatus=" + controlled.status
                + " capturedHttpsStatus=" + secure.status
                + " exitSourceIp=" + exitSourceIp
                + " token=" + args[1]
        );
    }

    private static void udpEcho(String host, int port, String label) throws Exception {
        if (port < 1 || port > 65_535 || label.isEmpty()) {
            throw new IllegalArgumentException("invalid UDP echo arguments");
        }
        byte[] payload = (
            "nvpn-android-underlay-" + label + "-" + UUID.randomUUID()
        ).getBytes(StandardCharsets.UTF_8);
        byte[] response = new byte[payload.length + 32];
        DatagramSocket socket = new DatagramSocket();
        try {
            socket.setSoTimeout(4_000);
            socket.connect(InetAddress.getByName(host), port);
            socket.send(new DatagramPacket(payload, payload.length));
            DatagramPacket reply = new DatagramPacket(response, response.length);
            socket.receive(reply);
            byte[] echoed = Arrays.copyOfRange(
                reply.getData(),
                reply.getOffset(),
                reply.getOffset() + reply.getLength()
            );
            if (!Arrays.equals(payload, echoed)) {
                throw new IllegalStateException("UDP fixture returned the wrong payload");
            }
            System.out.println(
                "udpEchoLabel=" + label
                    + " completionNanos=" + System.nanoTime()
                    + " bytes=" + echoed.length
            );
        } finally {
            socket.close();
        }
    }
}
