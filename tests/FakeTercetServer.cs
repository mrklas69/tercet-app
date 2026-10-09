using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace Tercet.Checks;

/// <summary>
/// Falešný server fronty pro Check-Sync.ps1 se stejným kontraktem jako
/// protokol fronty: GET s If-None-Match dá 304, PUT chce
/// If-Match (428 bez něj, 412 při jiné verzi), cizí token je 404. Běží na
/// vlastním vlákně, protože klient Tercetu je synchronní a test ho volá
/// z vlákna PowerShellu; obě strany na jednom vlákně by se zablokovaly.
/// Žije jen v testovacím procesu (Add-Type), stejně jako TestApplication.
/// </summary>
public sealed class FakeTercetServer : IDisposable
{
    private readonly HttpListener listener = new HttpListener();
    private readonly object gate = new object();

    public string Prefix { get; }
    // Token → přesné bajty uloženého dokumentu; test je nastavuje přímo.
    public Dictionary<string, byte[]> Documents { get; } = new Dictionary<string, byte[]>();
    // Jeden řádek na požadavek: metoda, cesta, token a podmínkové hlavičky.
    public List<string> Requests { get; } = new List<string>();
    // Nenulová hodnota = každá odpověď má tento stav (např. 503 při výpadku úložiště).
    public int FailWith { get; set; }
    // Simulace souběžné změny z jiného zařízení: po odbaveném GET se dokument
    // tiše nahradí, takže následující PUT narazí na 412.
    public byte[] ReplaceAfterGet { get; set; }
    public DateTimeOffset LastModified { get; set; } = new DateTimeOffset(2026, 9, 29, 8, 0, 0, TimeSpan.Zero);

    public FakeTercetServer()
    {
        // Volný port: TcpListener na portu 0 ho přidělí a hned uvolní.
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        int port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        Prefix = "http://127.0.0.1:" + port + "/";
        listener.Prefixes.Add(Prefix);
        listener.Start();
        var thread = new Thread(Loop) { IsBackground = true, Name = "FakeTercetServer" };
        thread.Start();
    }

    // Vzorec serveru (TercetStore.ComputeETag) opsaný záměrně, ne převzatý
    // z Tercet.dll: test tak ověří, že desktop počítá totéž nezávisle.
    public static string ComputeETag(byte[] content)
        => "\"" + Convert.ToHexString(SHA256.HashData(content)).ToLowerInvariant().Substring(0, 32) + "\"";

    public string ETagOf(string token) => ComputeETag(Documents[token]);

    private void Loop()
    {
        while (true)
        {
            HttpListenerContext context;
            try { context = listener.GetContext(); }
            catch (HttpListenerException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (InvalidOperationException) { return; }
            try { Handle(context); }
            catch (Exception ex)
            {
                lock (gate) { Requests.Add("ERROR " + ex.Message); }
                try { context.Response.Abort(); } catch (Exception) { }
            }
        }
    }

    private void Handle(HttpListenerContext context)
    {
        var request = context.Request;
        var response = context.Response;
        string token = request.Headers["X-Tercet-Token"] ?? "";
        string ifNoneMatch = request.Headers["If-None-Match"];
        string ifMatch = request.Headers["If-Match"];
        byte[] body;
        using (var buffer = new MemoryStream())
        {
            request.InputStream.CopyTo(buffer);
            body = buffer.ToArray();
        }
        lock (gate)
        {
            Requests.Add(request.HttpMethod + " " + request.Url.AbsolutePath + " token=" + token
                + " if-none-match=" + (ifNoneMatch ?? "-") + " if-match=" + (ifMatch ?? "-") + " bytes=" + body.Length);
            if (FailWith != 0) { Send(response, FailWith, "text/plain", Encoding.UTF8.GetBytes("Queue storage is unavailable.")); return; }
            if (request.Url.AbsolutePath != "/api/tercet") { Send(response, 404, null, null); return; }
            if (token.Length == 0) { Send(response, 400, "text/plain", Encoding.UTF8.GetBytes("Missing X-Tercet-Token header.")); return; }
            byte[] current;
            if (!Documents.TryGetValue(token, out current)) { Send(response, 404, null, null); return; }
            string etag = ComputeETag(current);
            switch (request.HttpMethod)
            {
                case "GET":
                    response.Headers["ETag"] = etag;
                    response.Headers["Last-Modified"] = LastModified.ToString("R");
                    if (ifNoneMatch == etag) Send(response, 304, null, null);
                    else Send(response, 200, "application/json; charset=utf-8", current);
                    if (ReplaceAfterGet != null) { Documents[token] = ReplaceAfterGet; ReplaceAfterGet = null; }
                    return;
                case "PUT":
                    if (ifMatch == null) { Send(response, 428, "text/plain", Encoding.UTF8.GetBytes("If-Match header with the current ETag is required.")); return; }
                    if (ifMatch != etag)
                    {
                        response.Headers["ETag"] = etag;
                        Send(response, 412, "text/plain", Encoding.UTF8.GetBytes("Queue was changed by someone else; reload it first."));
                        return;
                    }
                    Documents[token] = body;
                    response.Headers["ETag"] = ComputeETag(body);
                    Send(response, 204, null, null);
                    return;
                default:
                    Send(response, 405, null, null);
                    return;
            }
        }
    }

    private static void Send(HttpListenerResponse response, int status, string type, byte[] body)
    {
        response.StatusCode = status;
        if (type != null) response.ContentType = type;
        if (body != null && body.Length > 0)
        {
            response.ContentLength64 = body.Length;
            response.OutputStream.Write(body, 0, body.Length);
        }
        response.Close();
    }

    public void Dispose()
    {
        try { listener.Stop(); listener.Close(); }
        catch (ObjectDisposedException) { }
    }
}
