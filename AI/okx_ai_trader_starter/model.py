from dataclasses import dataclass
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, precision_score, recall_score

@dataclass
class TrainResult:
    model: object
    metrics: dict

def train_classifier(df: pd.DataFrame, feature_cols, label_col='up'):
    X = df[feature_cols]
    y = df[label_col]
    clf = RandomForestClassifier(n_estimators=200, max_depth=6, random_state=42, n_jobs=-1)
    clf.fit(X, y)
    yhat = clf.predict(X)
    metrics = {
        'acc_in': float(accuracy_score(y, yhat)),
        'prec_in': float(precision_score(y, yhat)),
        'rec_in': float(recall_score(y, yhat)),
    }
    return TrainResult(model=clf, metrics=metrics)

def walk_forward(df, feature_cols, label_col='up', train_ratio=0.7, steps=3):
    # Train/test in rolling windows.
    n = len(df)
    results = []
    start = 0
    for i in range(steps):
        split = int((start + n) * train_ratio)
        train = df.iloc[start:split]
        test = df.iloc[split:]
        if len(train) < 200 or len(test) < 50:
            break
        tr = train_classifier(train, feature_cols, label_col)
        Xtest, ytest = test[feature_cols], test[label_col]
        yhat = tr.model.predict(Xtest)
        results.append({
            'step': i+1,
            'train_start': str(train.index[0]),
            'train_end': str(train.index[-1]),
            'test_start': str(test.index[0]),
            'test_end': str(test.index[-1]),
            'acc_out': float((yhat == ytest).mean())
        })
        # advance window by 1/steps of the dataset
        start += int(n / steps)
        if start >= n - 100:
            break
    return tr.model, results
