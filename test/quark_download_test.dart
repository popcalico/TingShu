import 'package:flutter_test/flutter_test.dart';
import 'package:tingshu/services/quark/quark_api.dart';

void main() {
  group('夸克取直链：两种真实返回都要认', () {
    test('data 是数组（导致"能解析不能播"的那种）', () {
      final url = QuarkApi.extractDownloadUrl([
        {'fid': 'abc', 'download_url': 'https://cdn.example.com/a.mp3?sign=1'},
      ]);
      expect(url, 'https://cdn.example.com/a.mp3?sign=1');
    });

    test('data 是对象里的 list', () {
      final url = QuarkApi.extractDownloadUrl({
        'list': [
          {'download_url': 'https://cdn.example.com/b.mp3'},
        ],
      });
      expect(url, 'https://cdn.example.com/b.mp3');
    });

    test('字段叫 url 也认（旧版接口）', () {
      expect(
        QuarkApi.extractDownloadUrl([
          {'url': 'https://cdn.example.com/c.mp3'},
        ]),
        'https://cdn.example.com/c.mp3',
      );
    });

    test('空列表 → 明确报错，不抛类型异常', () {
      expect(
        () => QuarkApi.extractDownloadUrl(const []),
        throwsA(isA<QuarkException>()),
      );
      expect(
        () => QuarkApi.extractDownloadUrl({'list': const []}),
        throwsA(isA<QuarkException>()),
      );
    });

    test('拿到了记录但没有地址 → 用网盘给的提示', () {
      expect(
        () => QuarkApi.extractDownloadUrl([
          {'message': '该文件禁止下载'},
        ]),
        throwsA(
          isA<QuarkException>().having((e) => e.message, 'message', '该文件禁止下载'),
        ),
      );
    });

    test('乱七八糟的类型不崩', () {
      expect(
        () => QuarkApi.extractDownloadUrl('oops'),
        throwsA(isA<QuarkException>()),
      );
      expect(
        () => QuarkApi.extractDownloadUrl(null),
        throwsA(isA<QuarkException>()),
      );
    });
  });
}
