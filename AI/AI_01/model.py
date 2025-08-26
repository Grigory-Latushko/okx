import pandas as pd
from xgboost import XGBClassifier
from indicators import ema, rsi, atr
import joblib
import os

def prepare_features(df):
    df = df.copy()  # создаём безопасную копию
    df.loc[:, "ema9"] = ema(df["close"], 9)
    df.loc[:, "ema21"] = ema(df["close"], 21)
    df.loc[:, "rsi"] = rsi(df["close"], 14)
    df.loc[:, "atr"] = atr(df, 14)
    df.loc[:, "return"] = df["close"].pct_change().shift(-1)
    df.loc[:, "target"] = (df["return"] > 0).astype(int)
    df = df.dropna()
    features = ["ema9","ema21","rsi","atr"]
    return df[features], df["target"]

def train_or_load_model(df, inst):
    model_file = f"model_{inst}.joblib"
    if os.path.exists(model_file):
        model = joblib.load(model_file)
        print(f"Loaded existing model for {inst}")
    else:
        X, y = prepare_features(df)
        model = XGBClassifier(n_estimators=100, max_depth=3, eval_metric='logloss')
        model.fit(X, y)
        joblib.dump(model, model_file)
        print(f"Trained and saved model for {inst}")
    return model

def predict(model, df):
    X, _ = prepare_features(df)
    return model.predict_proba(X)[:,-1][-1]  # вероятность роста следующей свечи
