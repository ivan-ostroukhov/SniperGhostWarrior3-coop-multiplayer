// ============================================================================
// SGW3 CO-OP UDP BRIDGE v0.2
// ============================================================================

#define _WINSOCK_DEPRECATED_NO_WARNINGS
#include <winsock2.h>
#include <windows.h>
#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <chrono>

#pragma comment(lib, "ws2_32.lib")

constexpr uint16_t PORT = 27015;

std::string GetSaveDir() {
    char* userProfile = nullptr;
    size_t len = 0;
    _dupenv_s(&userProfile, &len, "USERPROFILE");
    std::string dir = userProfile ? userProfile : ".";
    free(userProfile);
    return dir + "\\Saved Games\\Sniper Ghost Warrior 3\\";
}

std::string ReadWholeFile(const std::string& path) {
    std::ifstream f(path, std::ios::in);
    if (!f.is_open()) return "";
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

void WriteWholeFile(const std::string& path, const std::string& content) {
    std::ofstream f(path, std::ios::out | std::ios::trunc);
    if (f.is_open()) {
        f << content;
    }
}

std::string GetLastLine(const std::string& text) {
    if (text.empty()) return "";
    size_t end = text.find_last_not_of("\r\n");
    if (end == std::string::npos) return "";
    size_t start = text.find_last_of("\r\n", end);
    if (start == std::string::npos) return text.substr(0, end + 1);
    return text.substr(start + 1, end - start);
}

int main() {
    SetConsoleTitleA("SGW3 Co-op UDP Network Bridge v0.1");
    std::string saveDir = GetSaveDir();

    std::string posOut = saveDir + "coop_pos_out.dat";
    std::string posIn  = saveDir + "coop_pos_in.dat";
    std::string evtOut = saveDir + "coop_evt_out.dat";
    std::string evtIn  = saveDir + "coop_evt_in.dat";

    WriteWholeFile(posOut, "");
    WriteWholeFile(posIn,  "");
    WriteWholeFile(evtOut, "");
    WriteWholeFile(evtIn,  "");

    std::cout << "========================================\n";
    std::cout << "   SGW3 CO-OP NETWORK BRIDGE v0.1\n";
    std::cout << "========================================\n";
    std::cout << "Work dir: " << saveDir << "\n";
    std::cout << "[OK] Old log files cleared!\n\n";

    std::string peerIp;
    std::cout << "Enter Partner IP (from Radmin VPN or 127.0.0.1 for local test): ";
    std::cin >> peerIp;

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);

    SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    u_long nonBlocking = 1;
    ioctlsocket(sock, FIONBIO, &nonBlocking);

    sockaddr_in localAddr{};
    localAddr.sin_family = AF_INET;
    localAddr.sin_port = htons(PORT);
    localAddr.sin_addr.s_addr = INADDR_ANY;

    if (bind(sock, reinterpret_cast<sockaddr*>(&localAddr), sizeof(localAddr)) == SOCKET_ERROR) {
        std::cerr << "[ERROR] Port " << PORT << " is already in use!\n";
        system("pause");
        return 1;
    }

    sockaddr_in peerAddr{};
    peerAddr.sin_family = AF_INET;
    peerAddr.sin_port = htons(PORT);
    peerAddr.sin_addr.s_addr = inet_addr(peerIp.c_str());

    std::cout << "\n[ONLINE] UDP Bridge active on port " << PORT << " -> " << peerIp << "\n";
    std::cout << "In game: Press [F6] to spawn partner, then [F7] to enable NET mode!\n\n";

    std::string lastPosData, lastEvtData, lastRecvEvtLine;
    char recvBuf[4096];
    sockaddr_in senderAddr{};
    int senderLen = sizeof(senderAddr);

    while (true) {
        std::string posData = ReadWholeFile(posOut);
        if (!posData.empty() && posData != lastPosData) {
            std::string pkt = "P:" + posData;
            sendto(sock, pkt.c_str(), static_cast<int>(pkt.size()), 0,
                   reinterpret_cast<sockaddr*>(&peerAddr), sizeof(peerAddr));
            lastPosData = posData;
        }

        std::string evtData = ReadWholeFile(evtOut);
        if (!evtData.empty() && evtData != lastEvtData) {
            std::string pkt = "E:" + evtData;
            for (int i = 0; i < 3; ++i) {
                sendto(sock, pkt.c_str(), static_cast<int>(pkt.size()), 0,
                       reinterpret_cast<sockaddr*>(&peerAddr), sizeof(peerAddr));
            }
            lastEvtData = evtData;
            std::cout << "[SENT] " << GetLastLine(evtData) << "\n";
        }

        while (true) {
            int bytes = recvfrom(sock, recvBuf, sizeof(recvBuf) - 1, 0,
                                 reinterpret_cast<sockaddr*>(&senderAddr), &senderLen);
            if (bytes <= 2) break;
            recvBuf[bytes] = '\0';
            std::string msg(recvBuf);

            if (msg.rfind("P:", 0) == 0) {
                WriteWholeFile(posIn, msg.substr(2));
            } else if (msg.rfind("E:", 0) == 0) {
                std::string evtPayload = msg.substr(2);
                WriteWholeFile(evtIn, evtPayload);
                std::string newestLine = GetLastLine(evtPayload);
                if (!newestLine.empty() && newestLine != lastRecvEvtLine) {
                    lastRecvEvtLine = newestLine;
                    std::cout << "[RECV] " << newestLine << "\n";
                }
            }
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(8));
    }

    closesocket(sock);
    WSACleanup();
    return 0;
}
