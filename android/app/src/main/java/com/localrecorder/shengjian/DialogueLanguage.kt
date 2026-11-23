package com.localrecorder.shengjian

import android.content.Context
import android.os.Build
import android.view.textclassifier.TextClassificationManager
import android.view.textclassifier.TextLanguage
import com.localrecorder.live.DialogueTurns

/** Call on a worker thread when the source text is final. Keep an uncertain system result unknown. */
internal fun dialogueLanguage(context: Context, text: String, languageA: String, languageB: String): String? {
    if (text.codePoints().noneMatch(Character::isLetter)) return null
    if (Build.VERSION.SDK_INT >= 29) {
        val classifier = context.getSystemService(TextClassificationManager::class.java)?.textClassifier
        val result = classifier?.detectLanguage(TextLanguage.Request.Builder(text).build())
        if (result != null && result.localeHypothesisCount > 0) {
            val best = result.getLocale(0)
            return best.language.takeIf { result.getConfidenceScore(best) >= 0.6f }
        }
    }
    return DialogueTurns.scriptLanguage(text, languageA, languageB)
}
