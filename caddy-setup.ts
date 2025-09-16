#!/usr/bin/env bun

import { $ } from "bun"
import { existsSync } from "fs"
import { resolve } from "path"

const DOMAIN = "xtc.localhost"
const PORT = 443 // Use port 443 to coexist with BSD
const PROJECT_DIR = resolve(import.meta.dir)
const WEB_DIST_DIR = resolve(PROJECT_DIR, "zig-out/web-dist")

const SECURITY_HEADERS: Record<string, string[]> = {
  "Cross-Origin-Embedder-Policy": ["require-corp"],
  "Cross-Origin-Opener-Policy": ["same-origin"]
}

async function setup() {
  console.log("🚀 XTC Web Development Setup")
  console.log(`Domain: https://${DOMAIN}`)
  console.log(`Serving: ${WEB_DIST_DIR}`)
  console.log()

  // Check if web-dist exists
  if (!existsSync(WEB_DIST_DIR)) {
    console.error("❌ Web distribution not found at", WEB_DIST_DIR)
    console.log("Run 'zig build web-dist' first")
    process.exit(1)
  }

  // Check if Caddy is running
  try {
    await $`curl -s http://localhost:2019/config/`.quiet()
    console.log("✓ Caddy API is accessible")
  } catch {
    console.error("❌ Caddy API not accessible at http://localhost:2019")
    console.log(
      "Make sure Caddy is running (the BSD setup should have started it)"
    )
    process.exit(1)
  }

  // Check for mkcert certificates
  const certFile = `${DOMAIN}+1.pem`
  const keyFile = `${DOMAIN}+1-key.pem`

  if (
    !existsSync(resolve(PROJECT_DIR, certFile)) ||
    !existsSync(resolve(PROJECT_DIR, keyFile))
  ) {
    console.log("📜 Generating SSL certificate for", DOMAIN)
    try {
      await $`mkcert ${DOMAIN} localhost`.cwd(PROJECT_DIR)
      console.log("✓ SSL certificate generated")
    } catch (error) {
      console.error(
        "❌ Failed to generate certificate. Make sure mkcert is installed and CA is set up"
      )
      console.log("Run: brew install mkcert && mkcert -install")
      process.exit(1)
    }
  } else {
    console.log("✓ SSL certificates found")
  }

  console.log("Configuring Caddy...")

  try {
    // First, check if there's an existing server on port 443
    const serversResponse = await fetch(
      "http://localhost:2019/config/apps/http/servers"
    )
    const servers = await serversResponse.json()

    let targetServer = null
    let serverName = null

    // Find the server listening on port 443
    for (const [name, config] of Object.entries(servers)) {
      if (config.listen && config.listen.includes(`:${PORT}`)) {
        targetServer = config
        serverName = name
        console.log(`✓ Found existing server '${name}' on port ${PORT}`)
        break
      }
    }

    if (!targetServer) {
      // Create a new server if none exists on port 443
      console.log("Creating new server configuration...")
      serverName = "xtc_server"
      targetServer = {
        listen: [`:${PORT}`],
        routes: []
      }
    }

    // Add or update XTC route
    const xtcRoute = {
      match: [
        {
          host: [DOMAIN]
        }
      ],
      handle: [
        {
          handler: "headers",
          response: {
            set: SECURITY_HEADERS
          }
        },
        {
          handler: "file_server",
          root: WEB_DIST_DIR,
          index_names: ["index.html"]
        }
      ]
    }

    // Remove any existing XTC routes
    if (targetServer.routes) {
      targetServer.routes = targetServer.routes.filter((route) => {
        const hosts = route.match?.[0]?.host || []
        return !hosts.includes(DOMAIN)
      })
    } else {
      targetServer.routes = []
    }

    // Add the new XTC route
    targetServer.routes.push(xtcRoute)

    // Update the server configuration
    const response = await fetch(
      `http://localhost:2019/config/apps/http/servers/${serverName}`,
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify(targetServer)
      }
    )

    if (!response.ok) {
      const error = await response.text()
      console.error("❌ Failed to configure server:", error)
      process.exit(1)
    }

    // Configure TLS certificates
    const tlsConfig = {
      certificates: {
        load_files: [
          {
            certificate: resolve(PROJECT_DIR, certFile),
            key: resolve(PROJECT_DIR, keyFile)
          }
        ]
      }
    }

    // Get existing TLS config and merge
    const tlsResponse = await fetch("http://localhost:2019/config/apps/tls")
    if (tlsResponse.ok) {
      const existingTls = await tlsResponse.json()
      if (existingTls?.certificates?.load_files) {
        // Check if our cert is already there
        const certPath = resolve(PROJECT_DIR, certFile)
        const alreadyHasCert = existingTls.certificates.load_files.some(
          (cert) => cert.certificate === certPath
        )

        if (!alreadyHasCert) {
          existingTls.certificates.load_files.push(
            tlsConfig.certificates.load_files[0]
          )
          tlsConfig.certificates.load_files =
            existingTls.certificates.load_files
        } else {
          console.log("✓ TLS certificate already configured")
        }
      }
    }

    const tlsUpdateResponse = await fetch(
      "http://localhost:2019/config/apps/tls",
      {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify(tlsConfig)
      }
    )

    if (!tlsUpdateResponse.ok) {
      const error = await tlsUpdateResponse.text()
      console.error("⚠️  Warning: Failed to configure TLS:", error)
    }

    console.log("✓ Caddy configured successfully")
    console.log()
    console.log("🌐 Access your site at:")
    console.log(`   https://${DOMAIN}`)
    console.log()
    console.log("📊 Caddy admin: http://localhost:2019/config/")
  } catch (error) {
    console.error("❌ Error configuring Caddy:", error)
    process.exit(1)
  }
}

async function remove() {
  console.log("Removing XTC configuration from Caddy...")

  try {
    // Get all servers
    const serversResponse = await fetch(
      "http://localhost:2019/config/apps/http/servers"
    )
    const servers = await serversResponse.json()

    let found = false

    // Find and update servers that have XTC routes
    for (const [serverName, config] of Object.entries(servers)) {
      if (config.routes) {
        const originalLength = config.routes.length
        config.routes = config.routes.filter((route) => {
          const hosts = route.match?.[0]?.host || []
          return !hosts.includes(DOMAIN)
        })

        if (config.routes.length < originalLength) {
          found = true
          console.log(`Removing XTC route from server '${serverName}'...`)

          // Update the server without the XTC route
          if (config.routes.length > 0) {
            // Server has other routes, update it
            const response = await fetch(
              `http://localhost:2019/config/apps/http/servers/${serverName}`,
              {
                method: "PUT",
                headers: {
                  "Content-Type": "application/json"
                },
                body: JSON.stringify(config)
              }
            )

            if (!response.ok) {
              const error = await response.text()
              console.error(
                `❌ Failed to update server '${serverName}':`,
                error
              )
            } else {
              console.log(`✓ Removed XTC route from server '${serverName}'`)
            }
          } else if (serverName === "xtc_server") {
            // This is our dedicated server with no other routes, delete it
            const response = await fetch(
              `http://localhost:2019/config/apps/http/servers/${serverName}`,
              {
                method: "DELETE"
              }
            )

            if (response.ok) {
              console.log(`✓ Removed dedicated XTC server '${serverName}'`)
            }
          }
        }
      }
    }

    if (!found) {
      console.log("ℹ XTC was not configured")
    } else {
      console.log("✓ XTC configuration removed from Caddy")
    }
  } catch (error) {
    console.error("❌ Error removing configuration:", error)
    process.exit(1)
  }
}

async function status() {
  console.log("📊 XTC Caddy Server Status")
  console.log("==========================")

  try {
    // Check if Caddy is running
    const testResponse = await fetch("http://localhost:2019/config/")
    if (!testResponse.ok) {
      console.error("❌ Caddy API not accessible")
      console.log("Make sure Caddy is running")
      return
    }

    // Get all servers
    const serversResponse = await fetch(
      "http://localhost:2019/config/apps/http/servers"
    )
    const servers = await serversResponse.json()

    let found = false

    // Look for XTC configuration in all servers
    for (const [serverName, config] of Object.entries(servers)) {
      if (config.routes) {
        for (const route of config.routes) {
          const hosts = route.match?.[0]?.host || []
          if (hosts.includes(DOMAIN)) {
            found = true
            console.log(`✓ XTC is configured in server '${serverName}'`)
            console.log(`   Listening on: ${config.listen.join(", ")}`)
            console.log(`   Serving from: ${route.handle[0].root}`)
            console.log()
            console.log(`🌐 https://${DOMAIN}`)

            // Check certificate
            const certFile = resolve(PROJECT_DIR, `${DOMAIN}+1.pem`)
            if (existsSync(certFile)) {
              console.log("✓ SSL certificate exists")
            } else {
              console.log(
                "⚠️  SSL certificate not found - run setup to generate"
              )
            }
            break
          }
        }
        if (found) break
      }
    }

    if (!found) {
      console.log("ℹ XTC is not configured")
      console.log("Run 'bun caddy-setup.ts' to configure")
    }

    // Show other configured hosts
    console.log()
    console.log("Other configured domains:")
    const allHosts = new Set()
    for (const config of Object.values(servers)) {
      if (config.routes) {
        for (const route of config.routes) {
          const hosts = route.match?.[0]?.host || []
          hosts.forEach((host) => {
            if (host !== DOMAIN) allHosts.add(host)
          })
        }
      }
    }

    if (allHosts.size > 0) {
      for (const host of allHosts) {
        console.log(`  - https://${host}`)
      }
    } else {
      console.log("  (none)")
    }
  } catch (error) {
    console.error("❌ Caddy API not accessible")
    console.log("Make sure Caddy is running")
  }
}

// Parse command line arguments
const command = process.argv[2]

switch (command) {
  case "remove":
    await remove()
    break
  case "status":
    await status()
    break
  case "setup":
  case undefined:
    await setup()
    break
  default:
    console.log("Usage: bun caddy-setup.ts [setup|remove|status]")
    console.log()
    console.log("Commands:")
    console.log("  setup   - Configure Caddy to serve XTC web-dist (default)")
    console.log("  remove  - Remove XTC configuration from Caddy")
    console.log("  status  - Check current configuration status")
    process.exit(1)
}
