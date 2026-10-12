/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourceDiscovery.hpp"

#include <libxml/HTMLparser.h>
#include <libxml/tree.h>
#include <libxml/uri.h>

#include <algorithm>
#include <chrono>
#include <deque>
#include <map>
#include <set>
#include <sstream>

namespace CydiaAPT {
namespace {
const std::size_t MaximumResponse = 2 * 1024 * 1024;
const std::size_t MaximumRequests = 64;
const std::size_t MaximumLinks = 256;
const unsigned MaximumDepth = 4;

std::string Lower(std::string value) {
    for (char &c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return value;
}
std::string Trim(const std::string &value) {
    const std::size_t begin(value.find_first_not_of(" \t\r\n"));
    if (begin == std::string::npos) return std::string();
    return value.substr(begin, value.find_last_not_of(" \t\r\n") - begin + 1);
}
bool Prefix(const std::string &value, const std::string &prefix) {
    return value.compare(0, prefix.size(), prefix) == 0;
}
bool Suffix(const std::string &value, const std::string &suffix) {
    return value.size() >= suffix.size() && value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}
int Hex(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
bool SafeEscapes(const std::string &uri) {
    for (std::size_t i(0); i < uri.size(); ++i) {
        if (uri[i] != '%') continue;
        if (i + 2 >= uri.size() || Hex(uri[i + 1]) < 0 || Hex(uri[i + 2]) < 0) return false;
        const unsigned char c(Hex(uri[i + 1]) * 16 + Hex(uri[i + 2]));
        if (c <= 32 || c == 127 || c == '/' || c == '\\' || c == '.' || c == '%' || c == '?' || c == '#') return false;
        i += 2;
    }
    return true;
}
bool SafePath(const std::string &path) {
    if (path.empty()) return true;
    std::string segment;
    for (std::size_t index(0); index <= path.size(); ++index) {
        if (index == path.size() || path[index] == '/') {
            if (segment == "..") return false;
            segment.clear(); continue;
        }
        const unsigned char c(path[index]);
        if (c <= 32 || c == 127 || c == '\\' || c == '?' || c == '#') return false;
        if (c == '%') {
            if (index + 2 >= path.size() || Hex(path[index + 1]) < 0 || Hex(path[index + 2]) < 0) return false;
            const unsigned char decoded(Hex(path[index + 1]) * 16 + Hex(path[index + 2]));
            // Reject path separators, traversal, nested escapes and control
            // spellings before a URI normalizer can erase their provenance.
            if (decoded <= 32 || decoded == 127 || decoded == '/' || decoded == '\\' ||
                decoded == '.' || decoded == '%' || decoded == '?' || decoded == '#') return false;
            segment += static_cast<char>(decoded); index += 2;
        } else segment += static_cast<char>(c);
    }
    return true;
}
struct ParsedURI {
    xmlURIPtr value;
    explicit ParsedURI(const std::string &uri) : value(xmlParseURI(uri.c_str())) {}
    ~ParsedURI() { if (value != NULL) xmlFreeURI(value); }
    ParsedURI(const ParsedURI &) = delete;
    ParsedURI &operator=(const ParsedURI &) = delete;
};
std::string String(const char *value) { return value == NULL ? std::string() : std::string(value); }
int Port(const xmlURI *uri) {
    if (uri->port > 0) return uri->port;
    return Lower(String(uri->scheme)) == "https" ? 443 : 80;
}
bool HTTP(const xmlURI *uri) {
    return uri != NULL && (Lower(String(uri->scheme)) == "https" || Lower(String(uri->scheme)) == "http") &&
        uri->server != NULL && *uri->server != '\0' && uri->query == NULL && uri->fragment == NULL && uri->opaque == NULL;
}
bool SameOrigin(const xmlURI *a, const xmlURI *b) {
    return HTTP(a) && HTTP(b) && Lower(String(a->scheme)) == Lower(String(b->scheme)) &&
        Lower(String(a->server)) == Lower(String(b->server)) && Port(a) == Port(b);
}
std::string RedactedURI(const std::string &uri) {
    ParsedURI parsed(uri);
    if (parsed.value == NULL) return std::string();
    if (parsed.value->user != NULL) { xmlFree(parsed.value->user); parsed.value->user = NULL; }
    xmlChar *saved(xmlSaveUri(parsed.value));
    if (saved == NULL) return std::string();
    const std::string result(reinterpret_cast<const char *>(saved)); xmlFree(saved); return result;
}
std::string RootURI(const std::string &requested) {
    if (requested.size() > 8192 || requested.find('\0') != std::string::npos || !SafeEscapes(requested)) return std::string();
    const ParsedURI parsed(requested);
    if (!HTTP(parsed.value) || !SafePath(String(parsed.value->path))) return std::string();
    std::string result(requested);
    if (result.empty() || result.back() != '/') result += '/';
    return result;
}
std::string ResolveLink(const std::string &base, const std::string &root, const std::string &href) {
    if (href.empty() || href.size() > 8192 || href.find('\0') != std::string::npos ||
        href.find('?') != std::string::npos || href.find('#') != std::string::npos || href.find('\\') != std::string::npos || !SafeEscapes(href)) return std::string();
    const ParsedURI input(href), rootURI(root);
    if (input.value == NULL || !SafePath(String(input.value->path))) return std::string();
    xmlChar *joined(xmlBuildURI(reinterpret_cast<const xmlChar *>(href.c_str()), reinterpret_cast<const xmlChar *>(base.c_str())));
    if (joined == NULL) return std::string();
    const std::string result(reinterpret_cast<const char *>(joined)); xmlFree(joined);
    const ParsedURI resolved(result);
    if (!SameOrigin(rootURI.value, resolved.value) || !SafePath(String(resolved.value->path)) ||
        !Prefix(String(resolved.value->path), String(rootURI.value->path))) return std::string();
    // A published absolute URL may omit credentials, but must never introduce
    // or substitute credentials from unverified directory contents.
    if (resolved.value->user != NULL && String(resolved.value->user) != String(rootURI.value->user)) return std::string();
    return result;
}
std::string Label(xmlNodePtr node) {
    xmlChar *content(xmlNodeGetContent(node));
    if (content == NULL) return std::string();
    std::string result;
    for (std::size_t i(0); content[i] != 0 && result.size() < 160; ++i)
        if (content[i] >= 32 && content[i] != 127) result += static_cast<char>(content[i]);
    xmlFree(content); return Trim(result);
}
struct Link { std::string uri, label; };
std::vector<Link> ListingLinks(const std::string &bytes, const std::string &base, const std::string &root) {
    std::vector<Link> links;
    if (bytes.empty() || bytes.size() > MaximumResponse || bytes.find('\0') != std::string::npos) return links;
    htmlDocPtr document(htmlReadMemory(bytes.data(), static_cast<int>(bytes.size()), NULL, "UTF-8",
        HTML_PARSE_NONET | HTML_PARSE_NODEFDTD | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING));
    if (document == NULL) return links;
    std::vector<xmlNodePtr> pending;
    if (xmlDocGetRootElement(document) != NULL) pending.push_back(xmlDocGetRootElement(document));
    std::set<std::string> seen;
    std::size_t visited(0);
    while (!pending.empty() && links.size() < MaximumLinks && visited++ < 16384) {
        xmlNodePtr node(pending.back()); pending.pop_back();
        if (node->next != NULL) pending.push_back(node->next);
        if (node->children != NULL) pending.push_back(node->children);
        if (node->type != XML_ELEMENT_NODE || xmlStrcasecmp(node->name, reinterpret_cast<const xmlChar *>("a")) != 0) continue;
        xmlChar *href(xmlGetProp(node, reinterpret_cast<const xmlChar *>("href")));
        if (href == NULL) continue;
        const std::string resolved(ResolveLink(base, root, reinterpret_cast<const char *>(href))); xmlFree(href);
        if (!resolved.empty() && seen.insert(resolved).second) links.push_back({resolved, Label(node)});
    }
    xmlFreeDoc(document);
    std::sort(links.begin(), links.end(), [](const Link &a, const Link &b) { return a.uri < b.uri; });
    return links;
}
bool Words(const std::string &value, std::vector<std::string> *words, bool architecture) {
    std::istringstream input(value);
    std::set<std::string> seen;
    for (std::string word; input >> word;) {
        if (word.size() > 128 || words->size() == 128) return false;
        for (unsigned char c : word) {
            if (c <= 32 || c == 127 || c == '#' || c == ':' || c == '\\') return false;
            if (architecture && !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
        }
        if (seen.insert(word).second) words->push_back(word);
    }
    return true;
}
bool ReleaseBody(const std::string &bytes, std::string *body, bool *clearSigned) {
    if (bytes.empty() || bytes.size() > MaximumResponse || bytes.find('\0') != std::string::npos) return false;
    *clearSigned = Prefix(bytes, "-----BEGIN PGP SIGNED MESSAGE-----");
    if (!*clearSigned) { *body = bytes; return true; }
    std::istringstream input(bytes);
    std::string line;
    bool headers(true), beginSignature(false), endSignature(false);
    std::getline(input, line);
    while (std::getline(input, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (headers) { if (line.empty()) headers = false; continue; }
        if (line == "-----BEGIN PGP SIGNATURE-----") { beginSignature = true; continue; }
        if (beginSignature) { if (line == "-----END PGP SIGNATURE-----") endSignature = true; continue; }
        if (Prefix(line, "- ")) line.erase(0, 2);
        *body += line + '\n';
    }
    return !headers && beginSignature && endSignature && !body->empty();
}
bool ChecksumField(const std::string &value, std::size_t digestLength) {
    std::istringstream lines(value);
    for (std::string line; std::getline(lines, line);) {
        if (Trim(line).empty()) continue;
        std::istringstream fields(line);
        std::string hash, size, path, extra;
        if (!(fields >> hash >> size >> path) || fields >> extra || hash.size() != digestLength || size.empty()) continue;
        bool valid(true);
        for (char c : hash) if (Hex(c) < 0) valid = false;
        for (char c : size) if (c < '0' || c > '9') valid = false;
        if (valid && SafePath(path)) return true;
    }
    return false;
}
bool ParseRelease(const std::string &bytes, const std::string &suite, const std::string &uri,
                  DiscoveredSourceSuite *result) {
    std::string body;
    bool clearSigned(false);
    if (!ReleaseBody(bytes, &body, &clearSigned)) return false;
    std::istringstream lines(body);
    std::map<std::string, std::string> fields;
    std::string current;
    bool ended(false);
    for (std::string line; std::getline(lines, line);) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) { if (!fields.empty()) ended = true; continue; }
        if (ended) return false;
        for (unsigned char c : line) if ((c < 32 && c != '\t') || c == 127) return false;
        if (line[0] == ' ' || line[0] == '\t') {
            if (current.empty()) return false;
            fields[current] += '\n' + Trim(line); continue;
        }
        const std::size_t colon(line.find(':'));
        if (colon == std::string::npos || colon == 0) return false;
        current = Lower(line.substr(0, colon));
        for (char c : current)
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
        if (fields.count(current) || fields.size() == 128) return false;
        fields[current] = Trim(line.substr(colon + 1));
    }
    const bool hasChecksums(ChecksumField(fields["sha256"], 64) || ChecksumField(fields["sha512"], 128) ||
        ChecksumField(fields["sha1"], 40) || ChecksumField(fields["md5sum"], 32));
    if (!hasChecksums) return false;
    DiscoveredSourceSuite parsed;
    parsed.suitePath = suite; parsed.metadataURI = RedactedURI(uri); parsed.clearSigned = clearSigned;
    if (!Words(fields["architectures"], &parsed.architectures, true) || !Words(fields["components"], &parsed.components, false)) return false;
    parsed.origin = fields["origin"].substr(0, 256); parsed.label = fields["label"].substr(0, 256);
    *result = parsed; return true;
}
unsigned Depth(const std::string &path) {
    unsigned depth(0); bool content(false);
    for (char c : path) {
        if (c == '/') { if (content) ++depth; content = false; }
        else content = true;
    }
    return depth + (content ? 1 : 0);
}
class Discovery {
    const std::string root_, temporaryParent_;
    const SourceDiscoveryFetcher fetch_;
    const std::function<bool()> cancelled_;
    const std::chrono::steady_clock::time_point deadline_;
    std::set<std::string> fetched_, queued_, keys_;
    std::deque<std::string> pending_;
    std::string dists_;
    SourceDiscoveryResult result_;

    void Warning(const char *code, const std::string &uri, SourceCheckStatus status) {
        if (result_.warnings.size() >= 16) return;
        SourceDiscoveryWarning warning; warning.code = code; warning.uri = RedactedURI(uri); warning.status = status;
        result_.warnings.push_back(warning);
    }
    bool Stop() {
        if (result_.status != SourceCheckStatus::Complete) return true;
        if (cancelled_ && cancelled_()) result_.status = SourceCheckStatus::Cancelled;
        else if (std::chrono::steady_clock::now() >= deadline_) result_.status = SourceCheckStatus::TimedOut;
        return result_.status != SourceCheckStatus::Complete;
    }
    SourceResourceResult Fetch(const std::string &uri) {
        SourceResourceResult response;
        if (Stop()) { response.status = result_.status; return response; }
        if (!fetched_.insert(uri).second) { response.status = SourceCheckStatus::Unavailable; return response; }
        if (result_.requestsPerformed == MaximumRequests) {
            result_.status = SourceCheckStatus::SizeLimit;
            Warning("request_limit", uri, result_.status); response.status = result_.status; return response;
        }
        SourceResourceRequest request; request.uri = uri; request.temporaryParent = temporaryParent_;
        request.maximumBytes = MaximumResponse;
        const long long milliseconds(std::chrono::duration_cast<std::chrono::milliseconds>(deadline_ - std::chrono::steady_clock::now()).count());
        request.timeoutSeconds = static_cast<unsigned>(std::max<long long>(1, std::min<long long>(20, (milliseconds + 999) / 1000)));
        ++result_.requestsPerformed;
        response = fetch_(request, [this]() { return (cancelled_ && cancelled_()) || std::chrono::steady_clock::now() >= deadline_; });
        if (Stop()) response.status = result_.status;
        else if (response.status == SourceCheckStatus::Cancelled) result_.status = response.status;
        if (response.status == SourceCheckStatus::Complete && response.bytes.size() > MaximumResponse) {
            response.bytes.clear(); response.status = SourceCheckStatus::SizeLimit;
        }
        if (response.status == SourceCheckStatus::SizeLimit) Warning("response_limit", uri, response.status);
        return response;
    }
    void Queue(const std::string &uri) {
        if (!Prefix(uri, dists_) || uri == dists_ || !Suffix(uri, "/")) return;
        const std::string relative(uri.substr(dists_.size()));
        if (relative.empty() || Depth(relative) > MaximumDepth || queued_.size() >= MaximumLinks) return;
        if (queued_.insert(uri).second) pending_.push_back(uri);
    }
    void Links(const SourceResourceResult &response, const std::string &uri) {
        if (response.status != SourceCheckStatus::Complete) return;
        for (const Link &link : ListingLinks(response.bytes, uri, root_)) {
            if (Suffix(link.uri, "/")) Queue(link.uri);
            else if (Suffix(link.uri, "/Release") || Suffix(link.uri, "/InRelease"))
                Queue(link.uri.substr(0, link.uri.rfind('/') + 1));
            const ParsedURI parsed(link.uri);
            const std::string path(parsed.value == NULL ? "" : String(parsed.value->path));
            const std::size_t slash(path.rfind('/'));
            const std::string leaf(Lower(path.substr(slash == std::string::npos ? 0 : slash + 1)));
            if ((Suffix(leaf, ".gpg") || Suffix(leaf, ".asc") || Suffix(leaf, ".pgp") ||
                 Suffix(leaf, ".pub") || Suffix(leaf, ".key")) && leaf != "release.gpg" &&
                leaf != "inrelease.asc" && keys_.size() < 16 && keys_.insert(link.uri).second)
                result_.keyLinks.push_back({link.uri, link.label});
        }
    }
    bool Metadata(const std::string &base, const std::string &suite, DiscoveredSourceSuite *metadata) {
        for (const char *name : {"InRelease", "Release"}) {
            const std::string uri(base + name);
            const SourceResourceResult response(Fetch(uri));
            if (Stop()) return false;
            if (response.status != SourceCheckStatus::Complete) continue;
            if (ParseRelease(response.bytes, suite, uri, metadata)) return true;
            Warning("invalid_metadata", uri, SourceCheckStatus::InvalidDefinition);
        }
        return false;
    }
  public:
    Discovery(const std::string &root, const std::string &temporaryParent, const SourceDiscoveryFetcher &fetch,
              const std::function<bool()> &cancelled) : root_(root), temporaryParent_(temporaryParent), fetch_(fetch),
        cancelled_(cancelled), deadline_(std::chrono::steady_clock::now() + std::chrono::seconds(60)), dists_(root + "dists/") {}
    SourceDiscoveryResult Run() {
        if (Stop()) return result_;
        Links(Fetch(root_), root_);
        DiscoveredSourceSuite flat;
        result_.flatMetadataAvailable = Metadata(root_, "./", &flat);
        if (!Stop()) Links(Fetch(dists_), dists_);
        while (!pending_.empty() && !Stop()) {
            const std::string uri(pending_.front()); pending_.pop_front();
            std::string suite(uri.substr(dists_.size())); suite.pop_back();
            DiscoveredSourceSuite metadata;
            if (Metadata(uri, suite, &metadata)) result_.suites.push_back(metadata);
            else if (!Stop()) Links(Fetch(uri), uri);
        }
        std::sort(result_.suites.begin(), result_.suites.end(), [](const DiscoveredSourceSuite &a, const DiscoveredSourceSuite &b) { return a.suitePath < b.suitePath; });
        result_.discoveryUnavailable = result_.suites.empty() && !result_.flatMetadataAvailable;
        if (result_.discoveryUnavailable && result_.status == SourceCheckStatus::Complete)
            Warning("options_unavailable", root_, SourceCheckStatus::Unavailable);
        return result_;
    }
};
} // namespace

SourceDiscoveryResult DiscoverSourceOptionsWithFetcher(const std::string &uri,
    const std::string &temporaryParent, const SourceDiscoveryFetcher &fetch, const std::function<bool()> &cancelled) {
    const std::string root(RootURI(uri));
    if (root.empty() || !fetch) {
        SourceDiscoveryResult result; result.status = SourceCheckStatus::Unavailable;
        SourceDiscoveryWarning warning; warning.code = "discovery_not_supported"; warning.status = SourceCheckStatus::Unavailable;
        result.warnings.push_back(warning); return result;
    }
    return Discovery(root, temporaryParent, fetch, cancelled).Run();
}
} // namespace CydiaAPT
