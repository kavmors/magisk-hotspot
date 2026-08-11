import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketAddress;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** DNS proxy for hotspot clients, with one locally authoritative IPv4 name. */
final class DnsServer {
    private static final int DNS_PORT = 53;
    private static final int MAX_PACKET = 65535;
    private static final int UPSTREAM_TIMEOUT_MS = 3000;

    private final ConnectivityManager connectivity;
    private final Inet4Address listenAddress;
    private final String domain;
    private final int listenPort;
    private final ExecutorService udpWorkers = Executors.newFixedThreadPool(8);
    private final ExecutorService tcpWorkers = Executors.newFixedThreadPool(4);
    private DatagramSocket udpSocket;
    private ServerSocket tcpSocket;

    DnsServer(Context context, String address, String domain, int port) throws IOException {
        connectivity = (ConnectivityManager)
                context.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (connectivity == null) throw new IOException("connectivity service unavailable");
        InetAddress parsedAddress = InetAddress.getByName(address);
        if (!(parsedAddress instanceof Inet4Address)) {
            throw new IOException("DNS listen address is not IPv4: " + address);
        }
        listenAddress = (Inet4Address) parsedAddress;
        this.domain = domain;
        listenPort = port;
    }

    void serve() throws IOException {
        udpSocket = new DatagramSocket(null);
        udpSocket.setReuseAddress(true);
        udpSocket.bind(new InetSocketAddress(listenAddress, listenPort));

        tcpSocket = new ServerSocket();
        tcpSocket.setReuseAddress(true);
        tcpSocket.bind(new InetSocketAddress(listenAddress, listenPort));

        Runtime.getRuntime().addShutdownHook(new Thread(this::close, "dns-shutdown"));
        Thread tcpThread = new Thread(this::serveTcp, "dns-tcp");
        tcpThread.start();
        System.out.println("DNS server listening on " + listenAddress.getHostAddress() + ":"
                + listenPort + " for " + domain);

        while (!udpSocket.isClosed()) {
            byte[] buffer = new byte[MAX_PACKET];
            DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
            try {
                udpSocket.receive(packet);
            } catch (IOException error) {
                if (udpSocket.isClosed()) return;
                throw error;
            }
            byte[] query = new byte[packet.getLength()];
            System.arraycopy(packet.getData(), packet.getOffset(), query, 0, query.length);
            SocketAddress client = packet.getSocketAddress();
            udpWorkers.execute(() -> handleUdp(query, client));
        }
    }

    private void serveTcp() {
        while (!tcpSocket.isClosed()) {
            try {
                Socket client = tcpSocket.accept();
                tcpWorkers.execute(() -> handleTcp(client));
            } catch (IOException error) {
                if (!tcpSocket.isClosed()) {
                    System.err.println("DNS TCP accept failed: " + error);
                }
            }
        }
    }

    private void handleUdp(byte[] query, SocketAddress client) {
        byte[] response = answerOrForwardUdp(query);
        if (response == null) response = DnsMessage.servfail(query);
        if (response == null) return;
        try {
            udpSocket.send(new DatagramPacket(response, response.length, client));
        } catch (IOException ignored) {
            // The client may have disconnected while an upstream query was pending.
        }
    }

    private byte[] answerOrForwardUdp(byte[] query) {
        byte[] local = DnsMessage.answerIfLocal(query, domain, listenAddress);
        if (local != null) return local;

        for (Resolver resolver : resolvers()) {
            try (DatagramSocket upstream = new DatagramSocket(null)) {
                upstream.setSoTimeout(UPSTREAM_TIMEOUT_MS);
                resolver.network.bindSocket(upstream);
                upstream.connect(resolver.address, DNS_PORT);
                upstream.send(new DatagramPacket(query, query.length));
                byte[] buffer = new byte[MAX_PACKET];
                DatagramPacket response = new DatagramPacket(buffer, buffer.length);
                upstream.receive(response);
                byte[] result = new byte[response.getLength()];
                System.arraycopy(response.getData(), response.getOffset(), result, 0, result.length);
                if (DnsMessage.isResponseFor(query, result)) return result;
            } catch (IOException ignored) {
                // Try the next DNS server or network.
            }
        }
        return null;
    }

    private void handleTcp(Socket client) {
        try (Socket ignored = client;
                InputStream input = new BufferedInputStream(client.getInputStream());
                OutputStream output = new BufferedOutputStream(client.getOutputStream())) {
            client.setSoTimeout(10000);
            while (true) {
                int high = input.read();
                if (high < 0) return;
                int low = input.read();
                if (low < 0) throw new EOFException("truncated DNS length");
                int length = (high << 8) | low;
                if (length == 0) return;
                byte[] query = readFully(input, length);
                byte[] response = DnsMessage.answerIfLocal(query, domain, listenAddress);
                if (response == null) response = forwardTcp(query);
                if (response == null) response = DnsMessage.servfail(query);
                if (response == null) return;
                output.write((response.length >>> 8) & 0xff);
                output.write(response.length & 0xff);
                output.write(response);
                output.flush();
            }
        } catch (IOException ignored) {
            // DNS clients routinely close TCP connections after one query.
        }
    }

    private byte[] forwardTcp(byte[] query) {
        for (Resolver resolver : resolvers()) {
            try (Socket upstream = new Socket()) {
                resolver.network.bindSocket(upstream);
                upstream.connect(new InetSocketAddress(resolver.address, DNS_PORT),
                        UPSTREAM_TIMEOUT_MS);
                upstream.setSoTimeout(UPSTREAM_TIMEOUT_MS);
                OutputStream output = upstream.getOutputStream();
                output.write((query.length >>> 8) & 0xff);
                output.write(query.length & 0xff);
                output.write(query);
                output.flush();
                InputStream input = upstream.getInputStream();
                int high = input.read();
                int low = input.read();
                if (high < 0 || low < 0) continue;
                byte[] response = readFully(input, (high << 8) | low);
                if (DnsMessage.isResponseFor(query, response)) return response;
            } catch (IOException ignored) {
                // Try the next DNS server or network.
            }
        }
        return null;
    }

    private List<Resolver> resolvers() {
        List<Resolver> result = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        Network active = connectivity.getActiveNetwork();
        addResolvers(active, result, seen);
        for (Network network : connectivity.getAllNetworks()) {
            if (network.equals(active)) continue;
            NetworkCapabilities capabilities = connectivity.getNetworkCapabilities(network);
            if (capabilities != null
                    && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                addResolvers(network, result, seen);
            }
        }
        return result;
    }

    private void addResolvers(Network network, List<Resolver> result, Set<String> seen) {
        if (network == null) return;
        LinkProperties properties = connectivity.getLinkProperties(network);
        if (properties == null) return;
        for (InetAddress address : properties.getDnsServers()) {
            String key = network + "/" + address.getHostAddress();
            if (!address.isAnyLocalAddress() && !address.isLoopbackAddress()
                    && !address.isLinkLocalAddress() && !address.isMulticastAddress()
                    && !address.equals(listenAddress) && seen.add(key)) {
                result.add(new Resolver(network, address));
            }
        }
    }

    private static byte[] readFully(InputStream input, int length) throws IOException {
        byte[] data = new byte[length];
        int offset = 0;
        while (offset < length) {
            int count = input.read(data, offset, length - offset);
            if (count < 0) throw new EOFException("truncated DNS message");
            offset += count;
        }
        return data;
    }

    private void close() {
        if (udpSocket != null) udpSocket.close();
        try {
            if (tcpSocket != null) tcpSocket.close();
        } catch (IOException ignored) {
            // Process shutdown will release the descriptor.
        }
        udpWorkers.shutdownNow();
        tcpWorkers.shutdownNow();
    }

    private static final class Resolver {
        final Network network;
        final InetAddress address;

        Resolver(Network network, InetAddress address) {
            this.network = network;
            this.address = address;
        }
    }
}
