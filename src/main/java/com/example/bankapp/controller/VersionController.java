package com.example.bankapp.controller;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class VersionController {

    @Value("${APP_COLOR:unknown}")
    private String color;

    @Value("${APP_VERSION:unknown}")
    private String version;

    @GetMapping(value = "/version", produces = "text/plain")
    public String version() {
        return "color=" + color + " version=" + version;
    }
}
