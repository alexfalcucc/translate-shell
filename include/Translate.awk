####################################################################
# Translate.awk                                                    #
####################################################################

# Detect external audio player (mplayer, mpv, mpg123).
function initAudioPlayer() {
    AudioPlayer = !system("mplayer" SUPOUT SUPERR) ?
        "mplayer" :
        (!system("mpv" SUPOUT SUPERR) ?
         "mpv" :
         (!system("mpg123 --version" SUPOUT SUPERR) ?
          "mpg123" :
          ""))
}

# Detect external speech synthesizer (say, espeak).
function initSpeechSynthesizer() {
    SpeechSynthesizer = !system("say ''" SUPOUT SUPERR) ?
        "say" :
        (!system("espeak ''" SUPOUT SUPERR) ?
         "espeak" :
         "")
}

# Detect external terminal pager (less, more, most).
function initPager() {
    Pager = !system("less -V" SUPOUT SUPERR) ?
        "less" :
        (!system("more -V" SUPOUT SUPERR) ?
         "more" :
         (!system("most" SUPOUT SUPERR) ?
          "most" :
          ""))
}

# Initialize `HttpService`.
function initHttpService() {
    HttpProtocol = "http://"
    HttpHost = "translate.google.com"
    HttpPort = 80
    if (Option["proxy"]) {
        match(Option["proxy"], /^(http:\/*)?([^\/]*):([^\/:]*)/, HttpProxySpec)
        HttpService = "/inet/tcp/0/" HttpProxySpec[2] "/" HttpProxySpec[3]
        HttpPathPrefix = HttpProtocol HttpHost
    } else {
        HttpService = "/inet/tcp/0/" HttpHost "/" HttpPort
        HttpPathPrefix = ""
    }
}

# Pre-process string (URL-encode before send).
function preprocess(text) {
    return quote(text)
}

# Post-process string (remove any redundant whitespace).
function postprocess(text) {
    text = gensub(/ ([.,;:?!"])/, "\\1", "g", text)
    text = gensub(/(["]) /, "\\1", "g", text)
    return text
}

# Send an HTTP request and get response from Google Translate.
function getResponse(text, sl, tl, hl,    content, header, url) {
    url = HttpPathPrefix "/translate_a/single?client=t"                 \
        "&ie=UTF-8&oe=UTF-8"                                            \
        "&dt=bd&dt=ex&dt=ld&dt=md&dt=qca&dt=rw&dt=rm&dt=ss&dt=t&dt=at"  \
        "&q=" preprocess(text) "&sl=" sl "&tl=" tl "&hl=" hl
    header = "GET " url " HTTP/1.1\n"           \
        "Host: " HttpHost "\n"                  \
        "Connection: close\n"
    if (Option["user-agent"])
        header = header "User-Agent: " Option["user-agent"] "\n"

    print header |& HttpService
    while ((HttpService |& getline) > 0) {
        if ($0 ~ /^\[.*\]/) content = $0
        l(sprintf("%4s bytes > %s", length($0), $0))
    }
    close(HttpService)

    return assert(content, "[ERROR] Null response.")
}

# Print a string (to output file or terminal pager).
function p(string) {
    if (Option["view"])
        print string | Option["pager"]
    else
        print string > Option["output"]
}

# Play using Google Text-to-Speech engine.
function play(text, tl,    url) {
    url = HttpProtocol HttpHost "/translate_tts?ie=UTF-8&client=t"	\
        "&tl=" tl "&q=" preprocess(text)

    # Don't use getline from pipe here - the same pipe will be run only once for each AWK script!
    system(Option["player"] " " parameterize(url) SUPOUT SUPERR)
}

# Get the translation of a string.
function getTranslation(text, sl, tl, hl,
                        isVerbose, toSpeech, returnPlaylist,
                        ####
                        r,
                        content, tokens, ast,
                        _sl, _tl, _hl, il, ils, isPhonetic,
                        article, example, explanation, ref, word,
                        translation, translations, phonetics,
                        wordClasses, words, segments, altTranslations,
                        original, oPhonetics, oWordClasses, oWords,
                        oRefs, oSynonymClasses, oSynonyms,
                        oExamples, oSeeAlso,
                        wShowOriginal, wShowOriginalPhonetics,
                        wShowTranslation, wShowTranslationPhonetics,
                        wShowPromptMessage, wShowLanguages,
                        wShowOriginalDictionary, wShowDictionary,
                        wShowAlternatives,
                        hasWordClasses, hasAltTranslations,
                        i, j, k, group, temp, saveSortedIn) {
    isPhonetic = match(tl, /^@/)
    tl = substr(tl, 1 + isPhonetic)

    if (!getCode(tl)) {
        # Check if target language is supported
        w("[WARNING] Unknown target language code: " tl)
    } else if (isRTL(tl)) {
        # Check if target language is R-to-L
        if (!FriBidi)
            w("[WARNING] " getName(tl) " is a right-to-left language, but FriBidi is not found.")
    }

    # Convert codes or aliases to standard codes used by Google Translate
    # If the code or alias cannot be found, use as it is
    _sl = getCode(sl); if (!_sl) _sl = sl
    _tl = getCode(tl); if (!_tl) _tl = tl
    _hl = getCode(hl); if (!_hl) _hl = hl
    content = getResponse(text, _sl, _tl, _hl)
    tokenize(tokens, content)
    parseJsonArray(ast, tokens)

    l(content, "content", 1, 1)
    l(tokens, "tokens", 1, 0, 1)
    l(ast, "ast")
    if (!isarray(ast) || !anything(ast)) {
        e("[ERROR] Oops! Something went wrong and I can't translate it for you :(")
        ExitCode = 1
        return
    }

    saveSortedIn = PROCINFO["sorted_in"]
    PROCINFO["sorted_in"] = "@ind_num_asc"
    for (i in ast) {
        if (i ~ "^0" SUBSEP "0" SUBSEP "[[:digit:]]+" SUBSEP "0$")
            append(translations, postprocess(literal(ast[i])))
        if (i ~ "^0" SUBSEP "0" SUBSEP "[[:digit:]]+" SUBSEP "1$")
            append(original, literal(ast[i]))
        if (i ~ "^0" SUBSEP "0" SUBSEP "[[:digit:]]+" SUBSEP "2$")
            append(phonetics, literal(ast[i]))
        if (i ~ "^0" SUBSEP "0" SUBSEP "[[:digit:]]+" SUBSEP "3$")
            append(oPhonetics, literal(ast[i]))

        # 1 - word classes and explanations
        if (match(i, "^0" SUBSEP "1" SUBSEP "([[:digit:]]+)" SUBSEP "0$", group))
            wordClasses[group[1]] = literal(ast[i])
        if (match(i, "^0" SUBSEP "1" SUBSEP "([[:digit:]]+)" SUBSEP "2" SUBSEP "([[:digit:]]+)" SUBSEP "([[:digit:]]+)$", group))
            words[group[1]][group[2]][group[3]] = literal(ast[i])
        if (match(i, "^0" SUBSEP "1" SUBSEP "([[:digit:]]+)" SUBSEP "2" SUBSEP "([[:digit:]]+)" SUBSEP "1" SUBSEP "([[:digit:]]+)$", group))
            words[group[1]][group[2]]["1"][group[3]] = literal(ast[i])

        # 5 - alternative translations
        if (match(i, "^0" SUBSEP "5" SUBSEP "([[:digit:]]+)" SUBSEP "0$", group)) {
            segments[group[1]] = literal(ast[i])
            altTranslations[group[1]][0] = ""
        }
        if (match(i, "^0" SUBSEP "5" SUBSEP "([[:digit:]]+)" SUBSEP "2" SUBSEP "([[:digit:]]+)" SUBSEP "0$", group))
            altTranslations[group[1]][group[2]] = postprocess(literal(ast[i]))

        # 8 - identified source languages
        if (i ~ "^0" SUBSEP "8" SUBSEP "0" SUBSEP "[[:digit:]]+$" ||
            i ~ "^0" SUBSEP "2$")
            append(ils, literal(ast[i]))

        # 11 - (original) word classes and synonyms
        if (match(i, "^0" SUBSEP "11" SUBSEP "([[:digit:]]+)" SUBSEP "0$", group))
            oSynonymClasses[group[1]] = literal(ast[i])
        if (match(i, "^0" SUBSEP "11" SUBSEP "([[:digit:]]+)" SUBSEP "1" SUBSEP "([[:digit:]]+)" SUBSEP "1$", group))
            if (ast[i]) {
                oRefs[literal(ast[i])][1] = group[1]
                oRefs[literal(ast[i])][2] = group[2]
            }
        if (match(i, "^0" SUBSEP "11" SUBSEP "([[:digit:]]+)" SUBSEP "1" SUBSEP "([[:digit:]]+)" SUBSEP "0" SUBSEP "([[:digit:]]+)$", group))
            oSynonyms[group[1]][group[2]][group[3]] = literal(ast[i])

        # 12 - (original) word classes and explanations
        if (match(i, "^0" SUBSEP "12" SUBSEP "([[:digit:]]+)" SUBSEP "0$", group))
            oWordClasses[group[1]] = literal(ast[i])
        if (match(i, "^0" SUBSEP "12" SUBSEP "([[:digit:]]+)" SUBSEP "1" SUBSEP "([[:digit:]]+)" SUBSEP "0$", group))
            oWords[group[1]][group[2]][0] = literal(ast[i])
        if (match(i, "^0" SUBSEP "12" SUBSEP "([[:digit:]]+)" SUBSEP "1" SUBSEP "([[:digit:]]+)" SUBSEP "1$", group))
            oWords[group[1]][group[2]][1] = literal(ast[i])
        if (match(i, "^0" SUBSEP "12" SUBSEP "([[:digit:]]+)" SUBSEP "1" SUBSEP "([[:digit:]]+)" SUBSEP "2$", group))
            oWords[group[1]][group[2]][2] = postprocess(literal(ast[i]))

        # 13 - (original) examples
        if (match(i, "^0" SUBSEP "13" SUBSEP "0" SUBSEP "([[:digit:]]+)" SUBSEP "0$", group))
            oExamples[group[1]] = postprocess(literal(ast[i]))

        # 14 - (original) see also
        if (match(i, "^0" SUBSEP "14" SUBSEP "0" SUBSEP "([[:digit:]]+)$", group))
            oSeeAlso[group[1]] = literal(ast[i])
    }
    PROCINFO["sorted_in"] = saveSortedIn

    translation = join(translations)

    il = !anything(ils) || belongsTo(sl, ils) ? sl : ils[0]

    # Generate output
    if (!isVerbose) {
        # Brief mode

        r = isPhonetic && anything(phonetics) ?
            prettify("brief-translation-phonetics", join(phonetics)) :
            prettify("brief-translation", s(translation, tl))

        if (toSpeech) {
            returnPlaylist[0]["text"] = translation
            returnPlaylist[0]["tl"] = tl
        }

    } else {
        # Verbose mode

        wShowOriginal = Option["show-original"]
        wShowOriginalPhonetics = Option["show-original-phonetics"]
        wShowTranslation = Option["show-translation"]
        wShowTranslationPhonetics = Option["show-translation-phonetics"]
        wShowPromptMessage = Option["show-prompt-message"]
        wShowLanguages = Option["show-languages"]
        wShowOriginalDictionary = Option["show-original-dictionary"]
        wShowDictionary = Option["show-dictionary"]
        wShowAlternatives = Option["show-alternatives"]

        if (!anything(oPhonetics)) wShowOriginalPhonetics = 0
        if (!anything(phonetics)) wShowTranslationPhonetics = 0
        if (getCode(il) == getCode(tl) &&                               \
            (isarray(oWordClasses) || isarray(oSynonymClasses) ||       \
             isarray(oExamples) || isarray(oSeeAlso))) {
            wShowOriginalDictionary = 1
            wShowTranslation = 0
        }
        hasWordClasses = exists(wordClasses)
        hasAltTranslations = exists(altTranslations[0])
        if (!hasWordClasses && !hasAltTranslations)
            wShowPromptMessage = wShowLanguages = 0
        if (!hasWordClasses) wShowDictionary = 0
        if (hasWordClasses || !hasAltTranslations) wShowAlternatives = 0

        if (wShowOriginal) {
            # Display: original text & phonetics
            if (r) r = r RS RS
            r = r m("-- display original text & phonetics")
            r = r prettify("original", s(join(original), il))
            if (wShowOriginalPhonetics)
                r = r RS prettify("original-phonetics", showPhonetics(join(oPhonetics), il))
        }

        if (wShowTranslation) {
            # Display: major translation & phonetics
            if (r) r = r RS RS
            r = r m("-- display major translation & phonetics")
            r = r prettify("translation", s(translation, tl))
            if (wShowTranslationPhonetics)
                r = r RS prettify("translation-phonetics", showPhonetics(join(phonetics), tl))
        }

        if (wShowPromptMessage || wShowLanguages)
            if (r) r = r RS
        if (wShowPromptMessage) {
            if (hasWordClasses) {
                # Display: prompt message (Definitions of ...)
                if (r) r = r RS
                r = r m("-- display prompt message (Definitions of ...)")
                if (isRTL(hl)) # home language is R-to-L
                    r = r prettify("prompt-message", s(showDefinitionsOf(hl, join(original))))
                else { # home language is L-to-R
                    split(showDefinitionsOf(hl, "\0%s\0"), group, "\0")
                    for (i = 1; i <= length(group); i++) {
                        if (group[i] == "%s")
                            r = r prettify("prompt-message-original", show(join(original), il))
                        else
                            r = r prettify("prompt-message", group[i])
                    }
                }
            } else if (hasAltTranslations) {
                # Display: prompt message (Translations of ...)
                if (r) r = r RS
                r = r m("-- display prompt message (Translations of ...)")
                if (isRTL(hl)) # home language is R-to-L
                    r = r prettify("prompt-message", s(showTranslationsOf(hl, join(original))))
                else { # home language is L-to-R
                    split(showTranslationsOf(hl, "\0%s\0"), group, "\0")
                    for (i = 1; i <= length(group); i++) {
                        if (group[i] == "%s")
                            r = r prettify("prompt-message-original", show(join(original), il))
                        else
                            r = r prettify("prompt-message", group[i])
                    }
                }
            }
        }
        if (wShowLanguages) {
            # Display: source language -> target language
            if (r) r = r RS
            r = r m("-- display source language -> target language")
            temp = Option["fmt-languages"]
            if (!temp) temp = "[ %s -> %t ]"
            split(temp, group, /(%s|%S|%t|%T)/)
            r = r prettify("languages", group[1])
            if (temp ~ /%s/)
                r = r prettify("languages-sl", getDisplay(il))
            if (temp ~ /%S/)
                r = r prettify("languages-sl", getName(il))
            r = r prettify("languages", group[2])
            if (temp ~ /%t/)
                r = r prettify("languages-tl", getDisplay(tl))
            if (temp ~ /%T/)
                r = r prettify("languages-tl", getName(tl))
            r = r prettify("languages", group[3])
        }

        if (wShowOriginalDictionary) {
            # Display: original dictionary
            if (exists(oWordClasses)) {
                # Detailed explanations
                if (r) r = r RS
                r = r m("-- display original dictionary (detailed explanations)")
                for (i = 0; i < length(oWordClasses); i++) {
                    r = (i > 0 ? r RS : r) RS prettify("original-dictionary-detailed-word-class", s(oWordClasses[i], hl))
                    for (j = 0; j < length(oWords[i]); j++) {
                        explanation = oWords[i][j][0]
                        ref = oWords[i][j][1]
                        example = oWords[i][j][2]

                        r = (j > 0 ? r RS : r) RS prettify("original-dictionary-detailed-explanation", ins(1, explanation, il))
                        if (example)
                            r = r RS prettify("original-dictionary-detailed-example", ins(2, "- \"" example "\"", il))
                        if (ref && isarray(oRefs[ref])) {
                            temp = prettify("original-dictionary-detailed-synonyms", ins(1, show(showSynonyms(hl), hl) ": "))
                            temp = temp prettify("original-dictionary-detailed-synonyms-item", show(oSynonyms[oRefs[ref][1]][oRefs[ref][2]][0], il))
                            for (k = 1; k < length(oSynonyms[oRefs[ref][1]][oRefs[ref][2]]); k++)
                                temp = temp prettify("original-dictionary-detailed-synonyms", ", ") \
                                    prettify("original-dictionary-detailed-synonyms-item", show(oSynonyms[oRefs[ref][1]][oRefs[ref][2]][k], il))
                            r = r RS temp
                        }
                    }
                }
            }
            if (exists(oSynonymClasses)) {
                # Synonyms
                r = r RS RS
                r = r m("-- display original dictionary (synonyms)")
                r = r prettify("original-dictionary-synonyms", s(showSynonyms(hl), hl))
                for (i = 0; i < length(oSynonymClasses); i++) {
                    r = (i > 0 ? r RS : r) RS prettify("original-dictionary-synonyms-word-class", ins(1, oSynonymClasses[i], hl))
                    for (j = 0; j < length(oSynonyms[i]); j++) {
                        temp = prettify("original-dictionary-synonyms-synonyms", ins(2, "- "))
                        temp = temp prettify("original-dictionary-synonyms-synonyms-item", show(oSynonyms[i][j][0], il))
                        for (k = 1; k < length(oSynonyms[i][j]); k++)
                            temp = temp prettify("original-dictionary-synonyms-synonyms", ", ") \
                                prettify("original-dictionary-synonyms-synonyms-item", show(oSynonyms[i][j][k], il))
                        r = r RS temp
                    }
                }
            }
            if (exists(oExamples)) {
                # Examples
                r = r RS RS
                r = r m("-- display original dictionary (examples)")
                r = r prettify("original-dictionary-examples", s(showExamples(hl), hl))
                for (i = 0; i < length(oExamples); i++) {
                    example = oExamples[i]

                    temp = prettify("original-dictionary-examples-example", ins(1, "- "))
                    split(example, group, /(\u003cb\u003e|\u003c\/b\u003e)/)
                    if (isRTL(il)) # target language is R-to-L
                        temp = temp show(group[1] group[2] group[3], il)
                    else # target language is L-to-R
                        temp = temp prettify("original-dictionary-examples-example", group[1]) \
                            prettify("original-dictionary-examples-original", group[2]) \
                            prettify("original-dictionary-examples-example", group[3])
                    r = (i > 0 ? r RS : r) RS temp
                }
            }
            if (exists(oSeeAlso)) {
                # See also
                r = r RS RS
                r = r m("-- display original dictionary (see also)")
                r = r prettify("original-dictionary-see-also", s(showSeeAlso(hl), hl))
                temp = ins(1, prettify("original-dictionary-see-also-phrases-item", show(oSeeAlso[0], il)))
                for (k = 1; k < length(oSeeAlso); k++)
                    temp = temp prettify("original-dictionary-see-also-phrases", ", ") \
                        prettify("original-dictionary-see-also-phrases-item", show(oSeeAlso[k], il))
                r = r RS temp
            }
        }

        if (wShowDictionary) {
            # Display: dictionary entries
            if (r) r = r RS
            r = r m("-- display dictionary entries")
            for (i = 0; i < length(wordClasses); i++) {
                r = (i > 0 ? r RS : r) RS prettify("dictionary-word-class", s(wordClasses[i], hl))
                for (j = 0; j < length(words[i]); j++) {
                    word = words[i][j][0]
                    article = words[i][j][4]
                    if (isRTL(il))
                        explanation = join(words[i][j][1], ", ")
                    else {
                        explanation = prettify("dictionary-explanation-item", words[i][j][1][0])
                        for (k = 1; k < length(words[i][j][1]); k++)
                            explanation = explanation prettify("dictionary-explanation", ", ") \
                                prettify("dictionary-explanation-item", words[i][j][1][k])
                    }

                    r = r RS prettify("dictionary-word", ins(1, (article ? "(" article ") " : "") word, tl))
                    if (isRTL(il))
                        r = r RS prettify("dictionary-explanation-item", ins(2, explanation, il))
                    else
                        r = r RS ins(2, explanation)
                }
            }
        }

        if (wShowAlternatives) {
            # Display: alternative translations
            if (r) r = r RS RS
            r = r m("-- display alternative translations")
            for (i = 0; i < length(altTranslations); i++) {
                r = (i > 0 ? r RS : r) prettify("alternatives-original", show(segments[i], il))
                if (isRTL(tl)) {
                    temp = join(altTranslations[i], ", ")
                    r = r RS prettify("alternatives-translations-item", ins(1, temp, tl))
                } else {
                    temp = prettify("alternatives-translations-item", altTranslations[i][0])
                    for (j = 1; j < length(altTranslations[i]); j++)
                        temp = temp prettify("alternatives-translations", ", ") \
                            prettify("alternatives-translations-item", altTranslations[i][j])
                    r = r RS ins(1, temp)
                }
            }
        }

        if (toSpeech) {
            if (index(showTranslationsOf(hl, "%s"), "%s") > 2) {
                returnPlaylist[0]["text"] = showTranslationsOf(hl)
                returnPlaylist[0]["tl"] = hl
                returnPlaylist[1]["text"] = join(original)
                returnPlaylist[1]["tl"] = il
            } else {
                returnPlaylist[0]["text"] = join(original)
                returnPlaylist[0]["tl"] = il
                returnPlaylist[1]["text"] = showTranslationsOf(hl)
                returnPlaylist[1]["tl"] = hl
            }
            returnPlaylist[2]["text"] = translation
            returnPlaylist[2]["tl"] = tl
        }
    }

    return r
}

# Translate a file.
function fileTranslation(uri,    group, temp1, temp2) {
    temp1 = Option["input"]
    temp2 = Option["verbose"]

    match(uri, /^file:\/\/(.*)/, group)
    Option["input"] = group[1]
    Option["verbose"] = 0

    translateMain()

    Option["input"] = temp1
    Option["verbose"] = temp2
}

# Start a browser session and translate a web page.
function webTranslation(uri, sl, tl, hl) {
    system(Option["browser"] " " parameterize("https://translate.google.com/translate?" \
                                              "hl=" hl "&sl=" sl "&tl=" tl "&u=" uri) "&")
}

# Translate the source text (into all target languages).
function translate(text, inline,
                   ####
                   i, j, playlist, saveSortedIn) {

    if (!getCode(Option["hl"])) {
        # Check if home language is supported
        w("[WARNING] Unknown language code: " Option["hl"] ", fallback to English: en")
        Option["hl"] = "en" # fallback to English
    } else if (isRTL(Option["hl"])) {
        # Check if home language is R-to-L
        if (!FriBidi)
            w("[WARNING] " getName(Option["hl"]) " is a right-to-left language, but FriBidi is not found.")
    }

    if (!getCode(Option["sl"])) {
        # Check if source language is supported
        w("[WARNING] Unknown source language code: " Option["sl"])
    } else if (isRTL(Option["sl"])) {
        # Check if source language is R-to-L
        if (!FriBidi)
            w("[WARNING] " getName(Option["sl"]) " is a right-to-left language, but FriBidi is not found.")
    }

    saveSortedIn = PROCINFO["sorted_in"]
    PROCINFO["sorted_in"] = "@ind_num_asc"
    for (i in Option["tl"]) {
        # Non-interactive verbose mode: separator between targets
        if (!Option["interactive"])
            if (Option["verbose"] && i > 1)
                p(prettify("target-seperator", replicate(Option["chr-target-seperator"], Option["width"])))

        if (inline &&
            startsWithAny(text, UriSchemes) == "file://") {
            # translate URL only from command-line parameters (inline)
            fileTranslation(text)
        } else if (inline &&
                   startsWithAny(text, UriSchemes) == "http://" ||
                   startsWithAny(text, UriSchemes) == "https://") {
            # translate URL only from command-line parameters (inline)
            webTranslation(text, Option["sl"], Option["tl"][i], Option["hl"])
        } else {
            p(getTranslation(text, Option["sl"], Option["tl"][i], Option["hl"], Option["verbose"], Option["play"], playlist))

            if (Option["play"])
                if (Option["player"])
                    for (j in playlist)
                        play(playlist[j]["text"], playlist[j]["tl"])
                else if (SpeechSynthesizer)
                    for (j in playlist)
                        print playlist[j]["text"] | SpeechSynthesizer
        }
    }
    PROCINFO["sorted_in"] = saveSortedIn
}

# Read from input and translate each line.
function translateMain(    i, line) {
    if (Option["interactive"])
        prompt()

    i = 0
    while (getline line < Option["input"]) {
        # Non-interactive verbose mode: separator between sources
        if (!Option["interactive"])
            if (Option["verbose"] && i++ > 0)
                p(prettify("source-seperator", replicate(Option["chr-source-seperator"], Option["width"])))

        if (Option["interactive"])
            repl(line)
        else
            translate(line)
    }
}
