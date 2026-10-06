package com.example.bankapp.controller;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.ModelAttribute;

@ControllerAdvice
public class VersionAdvice {

    @Value("${APP_COLOR:unknown}")
    private String color;

    @Value("${APP_VERSION:unknown}")
    private String version;

    @ModelAttribute("appColor")
    public String appColor() {
        return color;
    }

    @ModelAttribute("appVersion")
    public String appVersion() {
        return version;
    }
}
