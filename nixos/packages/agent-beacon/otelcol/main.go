package main

import (
	"fmt"
	"log"

	"go.opentelemetry.io/collector/component"
	"go.opentelemetry.io/collector/confmap"
	"go.opentelemetry.io/collector/confmap/provider/envprovider"
	"go.opentelemetry.io/collector/confmap/provider/fileprovider"
	"go.opentelemetry.io/collector/confmap/provider/yamlprovider"
	"go.opentelemetry.io/collector/otelcol"
)

// version is set by -ldflags "-X main.version=...".
var version = "dev"

func main() {
	info := component.BuildInfo{
		Command:     "beacon-otelcol",
		Description: "Beacon Endpoint Agent OpenTelemetry Collector (local-only build)",
		Version:     version,
	}

	set := otelcol.CollectorSettings{
		BuildInfo: info,
		Factories: components,
		ConfigProviderSettings: otelcol.ConfigProviderSettings{
			ResolverSettings: confmap.ResolverSettings{
				ProviderFactories: []confmap.ProviderFactory{
					envprovider.NewFactory(),
					fileprovider.NewFactory(),
					yamlprovider.NewFactory(),
				},
			},
		},
	}

	if err := otelcol.NewCommand(set).Execute(); err != nil {
		log.Fatal(fmt.Errorf("collector server run finished with error: %w", err))
	}
}
