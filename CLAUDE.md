# Stampo — как работать в этом репозитории

## Тесты

Пока задача в работе, весь набор не гоняется — только сьюты, которые касаются
изменённого кода:

```bash
bash Scripts/run-tests.sh \
  -only-testing:StampoTests/PanelMorphFrameTests \
  -only-testing:StampoTests/PanelRenderTests
```

После `StampoTests/` стоит имя типа сьюта (`@Suite struct …`), а не файла: в
одном файле их бывает несколько. Какие сьюты трогают изменённый тип —
`grep -l ИмяТипа StampoTests/*.swift`. После прогона сверить строку
`Tests reported: N`: число должно соответствовать выбранным сьютам, а не всему
набору.

Весь набор (`bash Scripts/run-tests.sh` без аргументов) запускается один раз,
когда задача закончена, и перед релизом (`RELEASING.md`, шаг 0). CI и так
гоняет его на каждый пуш.
